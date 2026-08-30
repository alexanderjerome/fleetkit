# pgweb read-only access export — bolt-on to the shared PostgreSQL
# surface (INFRA-42). Imported unconditionally from ./default.nix;
# inert unless this host runs Postgres AND exports at least one
# database via `infra.data.postgresql.pgwebAccess.databases`.
#
# Keys off services.postgresql.enable rather than the core module's
# enable, so it works for ANY Postgres host — whether configured
# through infra.data.postgresql (core), infra.timescale-db, infra.app-db
# or infra.analytics-db.
#
# On an exporting host this:
#   1. Declares the per-instance SOPS secret for the `pgweb` role
#      password (path convention shared with the pgweb LXC via
#      nix/lib/pgweb.nix). The key must exist in secrets.yaml or
#      activation fails — add it when adding a new PG host:
#        sk devtools secrets keys add dbs/pgweb/instances/<host> <pw>
#   2. Provisions the `pgweb` role: LOGIN + pg_read_all_data +
#      default_transaction_read_only=on + small connection cap.
#   3. pg_hba: `pgweb` may only connect from the pgweb LXC, rejected
#      everywhere else (mkBefore so these precede the broad subnet
#      allows; `local` socket rules are unaffected by `host` rules).
#
# Read-only layering (defense in depth, strongest first):
#   - pg_read_all_data grants SELECT/USAGE only; the role owns nothing.
#   - default_transaction_read_only=on at the role level.
#   - pgweb itself runs --readonly (statement filter, UX layer).
{ config, lib, ... }:
let
  inherit (lib) mkOption mkIf mkBefore types concatMapStringsSep;
  cfg = config.infra.data.postgresql.pgwebAccess;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  pgwebLib = import ../../../../lib/pgweb.nix { inherit lib; };

  secretKey = pgwebLib.instanceSecretKey config.networking.hostName;
  psql = "${config.services.postgresql.package}/bin/psql";
  active = config.services.postgresql.enable && cfg.enable && cfg.databases != [];
in
{
  options.infra.data.postgresql.pgwebAccess = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Advertise this host's databases to the fleet pgweb instance and
        provision the read-only `pgweb` role. Inert while `databases`
        is empty. Set false to keep a Postgres host out of pgweb.
      '';
    };

    databases = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "appdb" "analytics" ];
      description = ''
        Database names to expose in pgweb. The core module exports
        attrNames of infra.data.postgresql.databases automatically; hosts
        whose databases exist only at runtime (pgbackrest restores)
        list them explicitly in their host file. List definitions
        merge by concatenation.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5432;
      description = "Port the pgweb LXC should connect to.";
    };

    pgwebHostIp = mkOption {
      type = types.str;
      example = "192.0.2.10";
      description = "Internal IP of the pgweb LXC — pg_hba scope for the pgweb role.";
    };
  };

  config = mkIf active {
    sops.secrets.${secretKey} = sopsLib.mkSecret {
      restartUnits = [ "pgweb-ensure-role.service" ];
    } // { owner = "postgres"; };

    services.postgresql.authentication = mkBefore ''
      # pgweb read-only role — only from the pgweb LXC (INFRA-42)
      host    all   pgweb   ${cfg.pgwebHostIp}/32   scram-sha-256
      host    all   pgweb   0.0.0.0/0               reject
    '';

    systemd.services.pgweb-ensure-role = {
      description = "Provision read-only pgweb role from SOPS";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = ''
        ${psql} -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'pgweb'" | grep -q 1 \
          || ${psql} -c "CREATE ROLE pgweb LOGIN"
        ${psql} -c "ALTER ROLE pgweb WITH LOGIN CONNECTION LIMIT 8 PASSWORD '$(cat ${config.sops.secrets.${secretKey}.path})'"
        ${psql} -c "GRANT pg_read_all_data TO pgweb"
        ${psql} -c "ALTER ROLE pgweb SET default_transaction_read_only = on"
        # CONNECT is usually implied via PUBLIC; grant explicitly in
        # case a restored cluster revoked it. The DB may not exist yet
        # on restore-target hosts — tolerate.
        ${concatMapStringsSep "\n" (db: ''
          ${psql} -c "GRANT CONNECT ON DATABASE \"${db}\" TO pgweb" 2>/dev/null || true
        '') cfg.databases}
      '';
    };
  };
}
