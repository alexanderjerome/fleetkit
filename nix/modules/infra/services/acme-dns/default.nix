{ config, lib, pkgs, ... }:

# ADR-026 — acme-dns DNS-01 delegation server.
#
# Runs on the edge (ingress now, netcore post-ADR-025). Fleet hosts that
# issue a `<name>.<domain.base>` Let's Encrypt cert solve the DNS-01 challenge
# against THIS server using a low-privilege, per-host credential — so the
# raw Cloudflare API token no longer has to live on every UI host. acme-dns
# is authoritative for a delegated subdomain (default `acme-dns.<domain.base>`)
# and answers the `_acme-challenge.<name>.<domain.base>` TXT lookups that
# CNAME into it.
#
# Two listeners:
#   - DNS on :53 — PUBLIC. Let's Encrypt validators (multi-perspective, from
#     arbitrary networks) must reach it, so it cannot be IP-restricted. The
#     edge router must forward WAN :53 → this host (manual edge step when
#     the router is not declaratively managed).
#   - HTTP registration/update API — INTERNAL. Bound to the host's internal
#     interface and firewalled to the LAN/tailnet; never WAN-forwarded. Fleet
#     hosts hit it to update their own TXT; `fleet pki acme-dns register` hits it
#     once per host to mint a credential.

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.acme-dns;
in
{
  options.infra.acme-dns = {
    enable = mkEnableOption "acme-dns DNS-01 delegation server (ADR-026)";

    domain = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.base != null
                then "acme-dns.${config.fleet.settings.domain.base}" else null;
      defaultText = lib.literalExpression ''"acme-dns.''${config.fleet.settings.domain.base}"'';
      description = "Delegated subdomain acme-dns is authoritative for (NS-delegated from the parent zone in Cloudflare). Must be non-null when enabled (asserted).";
    };

    nsname = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.base != null
                then "ns.acme-dns.${config.fleet.settings.domain.base}" else null;
      defaultText = lib.literalExpression ''"ns.acme-dns.''${config.fleet.settings.domain.base}"'';
      description = "Authoritative nameserver FQDN. Needs a public glue A record (emitted by the Cloudflare resource) pointing at publicIp. Must be non-null when enabled (asserted).";
    };

    nsadmin = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.base != null
                then "admin.${config.fleet.settings.domain.base}" else null;
      defaultText = lib.literalExpression ''"admin.''${config.fleet.settings.domain.base}"'';
      description = "SOA RNAME (admin contact; '@' written as '.'). Must be non-null when enabled (asserted).";
    };

    publicIp = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.settings.network.wanIp;
      defaultText = lib.literalExpression "config.fleet.settings.network.wanIp";
      description = "Public IP returned for the apex/NS A records and used as the glue target. For an edge host this is the fleet WAN IP. Must be non-null when enabled (asserted).";
    };

    dnsListen = mkOption {
      type = types.str;
      default = "0.0.0.0:53";
      description = "Public DNS listener. Must be reachable from the internet (edge-router WAN :53 forward).";
    };

    apiAddress = mkOption {
      type = types.str;
      default = config.infra.networking.internalIp or "127.0.0.1";
      defaultText = "config.infra.networking.internalIp";
      description = "Bind IP for the registration/update HTTP API. Internal interface — reachable on the LAN/tailnet, never WAN.";
    };

    apiPort = mkOption {
      type = types.port;
      default = 8081;
      description = "Port for the registration/update HTTP API.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/acme-dns";
      description = "State directory (SQLite registration DB).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null && cfg.nsname != null && cfg.nsadmin != null;
        message = "infra.acme-dns.enable is set but domain/nsname/nsadmin are null — set fleet.settings.domain.base (or infra.acme-dns.{domain,nsname,nsadmin} explicitly).";
      }
      {
        assertion = cfg.publicIp != null;
        message = "infra.acme-dns.enable is set but infra.acme-dns.publicIp is null — set fleet.settings.network.wanIp (or infra.acme-dns.publicIp explicitly).";
      }
    ];

    services.acme-dns = {
      enable = true;
      settings = {
        general = {
          listen = cfg.dnsListen;
          protocol = "both";
          domain = cfg.domain;
          nsname = cfg.nsname;
          nsadmin = cfg.nsadmin;
          # Answers for the delegated zone itself, so the NS delegation
          # resolves and LE can find the authoritative server.
          records = [
            "${cfg.domain}. A ${cfg.publicIp}"
            "${cfg.domain}. NS ${cfg.nsname}."
            "${cfg.nsname}. A ${cfg.publicIp}"
          ];
        };
        api = {
          ip = cfg.apiAddress;
          port = cfg.apiPort;
          tls = "none";              # plain HTTP; bound internal-only.
          disable_registration = false;
        };
        database = {
          # Upstream NixOS module renamed the engine value "sqlite3"
          # → "sqlite" (nixpkgs 26.05). The acme-dns binary itself
          # still expects "sqlite3" on the wire, and the NixOS
          # module remaps under the hood — only the option's enum
          # changed shape.
          engine = "sqlite";
          connection = "${cfg.stateDir}/acme-dns.db";
        };
        logconfig = {
          loglevel = "info";
          logformat = "text";
        };
      };
    };

    # Public DNS port. The internal API port is opened too (LAN/tailnet
    # reachable for per-host TXT updates) — it is never WAN-forwarded, so
    # opening it here does not expose it to the internet.
    networking.firewall.allowedTCPPorts = [ 53 cfg.apiPort ];
    networking.firewall.allowedUDPPorts = [ 53 ];
  };
}
