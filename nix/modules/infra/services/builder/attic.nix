# atticd — Nix push cache backed by an S3-compatible store (e.g. in-fleet Garage).
#
# Architecture (ADR-019):
#   builds on build host  ─ post-build-hook ─►  atticd (port 8080, this host)
#                                                 │
#                                                 ▼
#                                       S3 store (e.g. Garage, bucket nix-cache)
#
# Closures built here (app packages, NixOS host closures) end up in the
# S3 store and survive loss of this build host. Every fleet host pulls
# from `https://<fqdn>/<cacheName>` first; upstream `cache.nixos.org` /
# `nix-community.cachix.org` remain in the substituter list as fallbacks
# for paths never built in-fleet.
#
# Bootstrap (one-time, after first deploy):
#   1. Mint a Garage access key + grant + save credentials to SOPS:
#        `fleet s3 mint-key nix-cache-key nix-cache --sops-prefix services/attic/garage`
#      Populates services/attic/garage/{access_key_id,secret_access_key,
#      endpoint,bucket,region}.
#   2. Generate the JWT secret with
#        `openssl genrsa -traditional 4096 | base64 -w0`
#      and store at `services/attic/jwt_secret_base64`.
#   3. After atticd is running, run `atticd-atticadm make-token --sub root
#      --validity 10y --pull '*' --push '*' --create-cache '*'` and store
#      at `services/attic/push_token` so the post-build-hook can upload.
#   4. Create the cache (name = cacheName below):
#        `attic login local https://<fqdn> <push_token>`
#        `attic cache create <cacheName>`
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.builder.attic;
  builderCfg = config.infra.builder;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;

  # Best-effort upload — never block a build on cache availability.
  # XDG_CONFIG_HOME=/etc: attic-client only reads $XDG_CONFIG_HOME/attic/
  # config.toml (never /etc/attic directly) — without this every hook
  # invocation fails with "No servers are available" and nothing is cached.
  postBuildHookScript = pkgs.writeShellScript "attic-post-build-hook" ''
    set -eu
    export HOME=/root
    export XDG_CONFIG_HOME=/etc
    timeout 60 ${pkgs.attic-client}/bin/attic push --jobs 4 \
      ${cfg.cacheName} $OUT_PATHS 2>&1 | ${pkgs.coreutils}/bin/head -c 4096 || true
  '';
in
{
  options.infra.builder.attic = {
    enable = mkEnableOption "atticd Nix binary cache (push target, Garage S3 backend)";

    listenPort = mkOption {
      type = types.port;
      default = 8080;
    };

    fqdn = mkOption {
      type = types.str;
      example = "attic.example.lan";
      description = ''
        Cache FQDN. If atticd runs on a substrate outside the fleet's
        internal zone (e.g. an XCP-ng tier-0 builder), pick a name in
        the substrate zone and have the hosting module register the A
        record (e.g. `fleet.xenZoneRecords.attic = "<ip>";`) so fleet
        DNS resolves it.
      '';
    };

    cacheName = mkOption {
      type = types.str;
      default = config.fleet.settings.name;
      defaultText = lib.literalExpression "config.fleet.settings.name";
      description = "Logical cache name inside atticd (created out-of-band via attic CLI).";
    };

    s3Bucket = mkOption {
      type = types.str;
      default = "nix-cache";
    };

    s3Endpoint = mkOption {
      type = types.str;
      example = "http://s3.example.lan:3900";
      description = ''
        S3 endpoint (e.g. in-fleet Garage). HTTP-direct to the store's
        native port is fine for fleet-internal traffic on a trusted L2 —
        no need to round-trip a TLS terminator. Switch to an https://
        endpoint when atticd is co-located with an untrusted boundary.
      '';
    };

    postBuildHook = mkOption {
      type = types.bool;
      default = true;
      description = "Install a post-build-hook so every local build uploads to atticd.";
    };
  };

  config = mkIf (builderCfg.enable && cfg.enable) {
    sops.secrets = {
      "services/attic/jwt_secret_base64"        = sopsLib.mkSecret { restartUnits = [ "atticd.service" ]; };
      "services/attic/garage/access_key_id"     = sopsLib.mkSecret { restartUnits = [ "atticd.service" ]; };
      "services/attic/garage/secret_access_key" = sopsLib.mkSecret { restartUnits = [ "atticd.service" ]; };
      "services/attic/push_token"               = sopsLib.mkSecret {};
    };

    sops.templates."atticd-env" = sopsLib.mkTemplate {
      content = ''
        ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${p."services/attic/jwt_secret_base64"}
        AWS_ACCESS_KEY_ID=${p."services/attic/garage/access_key_id"}
        AWS_SECRET_ACCESS_KEY=${p."services/attic/garage/secret_access_key"}
      '';
    };

    # System-wide attic client config so root's post-build-hook can authenticate.
    sops.templates."attic-client-config" = sopsLib.mkTemplate {
      content = ''
        default-server = "local"

        [servers.local]
        endpoint = "https://${cfg.fqdn}/"
        token = "${p."services/attic/push_token"}"
      '';
    };

    environment.etc."attic/config.toml".source =
      config.sops.templates."attic-client-config".path;

    services.atticd = {
      enable = true;
      environmentFile = config.sops.templates."atticd-env".path;
      settings = {
        listen = "[::]:${toString cfg.listenPort}";

        chunking = {
          nar-size-threshold = 65536;
          min-size = 16384;
          avg-size = 65536;
          max-size = 262144;
        };

        compression = {
          type = "zstd";
          level = 8;
        };

        storage = {
          type = "s3";
          region = "us-east-1";
          bucket = cfg.s3Bucket;
          endpoint = cfg.s3Endpoint;
        };

        database = {
          url = "sqlite:///var/lib/atticd/server.db?mode=rwc";
        };
      };
    };

    # Per-build upload. Best-effort, capped by `timeout` and `|| true`
    # in the hook script so a misbehaving attic never wedges a build.
    nix.settings.post-build-hook = mkIf cfg.postBuildHook (toString postBuildHookScript);

    # Attic client must be reachable from the script's PATH and HOME.
    environment.systemPackages = [ pkgs.attic-client ];

    # No Alloy scrape: atticd serves no /metrics endpoint (GET /metrics is a
    # 404), so a scrape job can only ever produce up{job="atticd"} == 0 and a
    # permanently-firing ServiceDown alert (INFRA-146). Availability is
    # monitored via node_systemd_unit_state (see grafana-stack/default.nix).

    infra.caddy.virtualHosts.${cfg.fqdn}.extraConfig = ''
      reverse_proxy http://127.0.0.1:${toString cfg.listenPort}
    '';

    # DNS alias (fqdn → this host) is published via
    # nix/fleet/dns/serviceAliasMap. Module-level fleet.* writes can't
    # cross to netcore's CoreDNS view (the module's config block only
    # fires on the host where atticd is enabled), so the alias has to
    # live in the fleet-scoped manifest where every host sees it.

    infra.services.attic = {
      port = cfg.listenPort;
      description = "atticd Nix binary cache (push target, Garage S3 backend)";
      category = "build";
      tags = [ "nix" "cache" "s3" ];
      # Auto Caddy wiring registers <name>.<domain.internal> +
      # (devDomain) <name>.<domain.base> vhosts. When atticd runs on a
      # separate substrate its canonical FQDN is `fqdn` (manually
      # declared above). Disable the auto-generated vhosts so Caddy
      # doesn't waste step-ca cert orders on stale names. Firewall +
      # service catalog still fire from this registration.
      caddy.enable = false;
    };
  };
}
