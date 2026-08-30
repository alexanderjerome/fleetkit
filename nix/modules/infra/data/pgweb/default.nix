# pgweb — read-only web UI over every fleet Postgres (INFRA-42).
#
# Aggregation: this module pulls each hive node's
# `infra.data.postgresql.pgwebAccess` export (see
# nix/modules/postgresql/pgweb-access.nix) through Colmena's `nodes`
# module argument and renders one bookmark TOML per (host, database)
# pair via the constructor in nix/lib/pgweb.nix. A new PG host or a
# new database on an existing host appears here on the next deploy of
# the pgweb host — no wiring on this side.
#
# `nodes` is only populated under Colmena eval; the plain
# nixosConfigurations output evaluates with the `? {}` default and
# renders zero bookmarks. Deploys go through `fleet deploy nixos`
# (Colmena), so the deployed artifact always has the full set.
# Building this host forces partial eval of every other node's config
# — expect a slower eval than single-host modules.
#
# Access layering: pgweb binds 127.0.0.1 only; reached via the
# per-host Caddy vhost (https://pgweb.<domain.internal>, step-ca cert)
# with HTTP basic auth from SOPS on top. DB side is the read-only
# `pgweb` role; --readonly here is just the final UX guard.
{ config, lib, pkgs, nodes ? {}, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.data.pgweb;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  pgwebLib = import ../../../../lib/pgweb.nix { inherit lib; };
  p = config.sops.placeholder;

  # PG nodes advertising at least one database. Self excluded (this
  # host runs no Postgres; guards against eval recursion regardless).
  pgNodes = lib.filterAttrs (name: node:
    name != config.networking.hostName
    && node.config.services.postgresql.enable
    && node.config.infra.data.postgresql.pgwebAccess.enable
    && node.config.infra.data.postgresql.pgwebAccess.databases != []
  ) nodes;

  bookmarks = lib.concatLists (lib.mapAttrsToList (name: node:
    pgwebLib.bookmarksOf {
      hostName = name;
      nodeCfg = node.config;
      mkPassword = h: p.${pgwebLib.instanceSecretKey h};
    }
  ) pgNodes);

  bookmarksDir = "/run/pgweb/bookmarks";
  templateName = b: "pgweb-bookmark-${b.name}.toml";
in
{
  options.infra.data.pgweb = {
    enable = mkEnableOption "pgweb — read-only Postgres web UI for the whole fleet";

    httpPort = mkOption {
      type = types.port;
      default = 8081;
      description = "Local HTTP port (proxied by the per-host Caddy).";
    };

    authUser = mkOption {
      type = types.str;
      default = config.fleet.settings.name;
      defaultText = lib.literalExpression "config.fleet.settings.name";
      description = "HTTP basic auth username (password from SOPS services/pgweb/auth_password). Only used when auth.enable.";
    };

    auth.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        HTTP basic auth in front of pgweb. Set false to rely solely on the
        network gate — tailnet reachability via `tailscale serve` + the
        headscale ACL (ADR-036). Acceptable for this read-only,
        `--bookmarks-only` UI; note the ACL is currently wide-open `*:*`,
        so "on the tailnet" today means any tailnet node, not just admins.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.pgweb = {
      isSystemUser = true;
      group = "pgweb";
      description = "pgweb service user";
    };
    users.groups.pgweb = {};

    # Per-instance role passwords (declared on the PG hosts too — same
    # key, shared via nix/lib/pgweb.nix) + the basic-auth password.
    sops.secrets = builtins.listToAttrs (map (name: {
      name = pgwebLib.instanceSecretKey name;
      value = sopsLib.mkSecret { restartUnits = [ "pgweb.service" ]; };
    }) (builtins.attrNames pgNodes)) // lib.optionalAttrs cfg.auth.enable {
      "services/pgweb/auth_password" = sopsLib.mkSecret {
        restartUnits = [ "pgweb.service" ];
      };
    };

    sops.templates = builtins.listToAttrs (map (b: {
      name = templateName b;
      value = sopsLib.mkTemplate {
        content = b.content;
        owner = "pgweb";
        mode = "0400";
        restartUnits = [ "pgweb.service" ];
      };
    }) bookmarks) // lib.optionalAttrs cfg.auth.enable {
      "pgweb-env" = sopsLib.mkTemplate {
        content = ''
          PGWEB_AUTH_USER=${cfg.authUser}
          PGWEB_AUTH_PASS=${p."services/pgweb/auth_password"}
        '';
        owner = "pgweb";
        mode = "0400";
        restartUnits = [ "pgweb.service" ];
      };
    };

    systemd.services.pgweb = {
      description = "pgweb — read-only Postgres web UI";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # Assemble the bookmarks dir from the rendered sops templates.
      # --bookmarks-only means the UI can connect to exactly this set.
      preStart = ''
        mkdir -p ${bookmarksDir}
        ${lib.concatMapStrings (b: ''
          install -m 0400 ${config.sops.templates.${templateName b}.path} ${bookmarksDir}/${b.name}.toml
        '') bookmarks}
      '';

      serviceConfig = {
        User = "pgweb";
        Group = "pgweb";
        RuntimeDirectory = "pgweb";
        RuntimeDirectoryMode = "0700";
        # Only present when auth.enable — without it pgweb starts with no
        # PGWEB_AUTH_* and serves unauthenticated (gated by the tailnet).
        EnvironmentFile = lib.mkIf cfg.auth.enable config.sops.templates."pgweb-env".path;
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.pgweb}/bin/pgweb"
          "--bind=127.0.0.1"
          "--listen=${toString cfg.httpPort}"
          "--sessions"
          "--readonly"
          "--bookmarks-only"
          "--bookmarks-dir=${bookmarksDir}"
          "--skip-open"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening — stateless UI, nothing to write outside /run.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    infra.services.pgweb = {
      port = cfg.httpPort;
      description = "pgweb — read-only web UI over all fleet Postgres databases";
      category = "platform";
      tags = [ "internal" "postgres" ];
    };
  };
}
