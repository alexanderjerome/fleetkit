# Unified service registry — single source of truth for ports, firewall, Caddy, and docs.
#
# Every registered service gets its firewall port(s) opened. Caddy is opt-in on top.
# A JSON service catalog is generated at /etc/fleet/services.json for CI/CD reference.
#
# Usage in an infra module's config block:
#
#   # UI service behind Caddy:
#   infra.services.komodo = {
#     port = cfg.corePort;
#     description = "Deployment management UI and API";
#     category = "platform";
#   };
#
#   # Service with extra ports (all opened in firewall):
#   infra.services.auth = {
#     port = cfg.serverPort;
#     extraPorts = [ { port = cfg.httpsPort; protocol = "https"; } ];
#     description = "Authentik identity provider";
#     category = "platform";
#   };
#
#   # Internal-only (no Caddy):
#   infra.services.loki = {
#     port = cfg.loki.httpPort;
#     caddy.enable = false;
#     description = "Log aggregation push endpoint";
#     category = "observability";
#   };
#
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkIf types;
  cfg = config.infra.services;

  domain = config.fleet.settings.domain.internal;
  hostIp = config.infra.networking.internalIp;
  hostName = config.networking.hostName;

  caddyServices = lib.filterAttrs (_: svc: svc.caddy.enable) cfg;

  # All ports from a service (primary + extras), for firewall.
  allPorts = svc:
    [ svc.port ] ++ map (ep: ep.port) svc.extraPorts;

  # Build URL objects for the catalog.
  urlsOf = _name: svc:
    let
      caddyHostname =
        if svc.caddy.hostname != null
        then "${svc.caddy.hostname}.${domain}"
        else "${hostName}.${domain}";
      path = if svc.caddy.path == "/" then "" else svc.caddy.path;
    in {
      internal = "http://${hostIp}:${toString svc.port}${path}";
      external =
        if svc.caddy.enable
        then "https://${caddyHostname}${path}"
        else "http://${hostName}.${domain}:${toString svc.port}${path}";
    };

  # Build ports array with ui flag for the catalog.
  portsOf = svc:
    [{ port = svc.port; ui = svc.caddy.enable; protocol = "http"; }]
    ++ map (ep: {
      inherit (ep) port protocol;
      ui = ep.ui;
    }) svc.extraPorts;

  # JSON catalog: one entry per service with all useful metadata.
  catalogEntries = lib.mapAttrs (name: svc: {
    inherit (svc) description category tags;
    host = hostName;
    ip = hostIp;
    urls = urlsOf name svc;
    ports = portsOf svc;
    caddy = svc.caddy.enable;
  }) cfg;

  catalogJson = builtins.toJSON catalogEntries;
in
{
  options.infra.services = mkOption {
    type = types.attrsOf (types.submodule ({ name, ... }: {
      options = {
        port = mkOption {
          type = types.port;
          description = "Primary port. Opened in firewall; proxied by Caddy when caddy.enable = true.";
        };
        extraPorts = mkOption {
          type = types.listOf (types.submodule {
            options = {
              port = mkOption {
                type = types.port;
                description = "Additional port to open in the firewall.";
              };
              ui = mkOption {
                type = types.bool;
                default = false;
                description = "Whether this port serves a UI (for catalog display).";
              };
              protocol = mkOption {
                type = types.str;
                default = "tcp";
                description = "Protocol hint for documentation (e.g., http, https, grpc, tcp).";
              };
            };
          });
          default = [];
          description = "Additional ports to open in the firewall (e.g., HTTPS, metrics, gRPC).";
        };
        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Upstream host for Caddy. Defaults to localhost.";
        };
        description = mkOption {
          type = types.str;
          default = "";
          description = "Human-readable description. Shows up in the service catalog.";
        };
        category = mkOption {
          type = types.str;
          default = "uncategorized";
          description = "Service category (e.g., platform, observability, workload, network).";
        };
        tags = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Freeform tags for filtering (e.g., [ \"internal\" \"docker\" ]).";
        };
        caddy = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Also reverse-proxy the primary port through the local Caddy.";
          };
          hostname = mkOption {
            type = types.nullOr types.str;
            default = name;
            description = "FQDN prefix under the internal domain (<hostname>.<fleet.settings.domain.internal>). Defaults to attr name. Null = path-only under host FQDN.";
          };
          path = mkOption {
            type = types.str;
            default = "/";
            description = "URL path. '/' = own vhost. '/foo' = path under the service hostname on the internal domain.";
          };
        };
      };
    }));
    default = {};
    description = "Service registry. Infra modules register here; firewall, Caddy, and docs are derived automatically.";
  };

  config = mkIf (cfg != {}) {
    # Every registered service gets all its ports opened in the firewall.
    networking.firewall.allowedTCPPorts =
      lib.unique (builtins.concatLists (lib.mapAttrsToList (_: allPorts) cfg));

    # Services with caddy.enable get a Caddy vhost on the primary port.
    infra.caddy.services = lib.mapAttrs (name: svc: {
      name = if svc.caddy.hostname != null then svc.caddy.hostname else name;
      port = svc.port;
      host = svc.host;
      path = svc.caddy.path;
    }) caddyServices;

    # Write service catalog JSON for CI/CD and documentation.
    environment.etc."fleet/services.json" = {
      text = catalogJson;
      mode = "0644";
    };
  };
}
