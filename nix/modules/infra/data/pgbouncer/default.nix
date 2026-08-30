# Co-located PgBouncer connection pooler (INFRA-95 / ADR-050).
#
# Host-agnostic: works in front of whatever local PostgreSQL a host runs
# (infra.data.postgresql, infra.app-db, infra.timescale-db, …). Clients point their
# DSN at `listenPort` (pooled) instead of the PostgreSQL `backendPort` (direct),
# so a new client connect borrows a warm backend instead of forking one — which
# is the ~1s-per-connect cost on the marketing/timescale DBs.
#
# Enable per host and list the databases to expose:
#   infra.data.pgbouncer = { enable = true; databases = [ "app_db" ]; };
#
# `transaction` pool mode is aggressive reuse — safe for plain query/CRUD
# workloads, NOT for clients that depend on session state (session-held prepared
# statements, advisory locks, LISTEN/NOTIFY, persistent SET). Keep DDL/migration
# DSNs pointed at the direct backendPort.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types concatStringsSep concatMapStringsSep;
  cfg = config.infra.data.pgbouncer;
in {
  options.infra.data.pgbouncer = {
    enable = mkEnableOption "co-located PgBouncer connection pooler";

    databases = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Database names to expose through PgBouncer (routed to the local PostgreSQL).";
      example = [ "app_db" ];
    };

    listenPort = mkOption {
      type = types.port;
      default = 6432;
      description = "Port PgBouncer listens on (the pooled port clients connect to).";
    };

    backendPort = mkOption {
      type = types.port;
      default = 5432;
      description = "Port the local PostgreSQL listens on (PgBouncer connects here).";
    };

    poolMode = mkOption {
      type = types.enum [ "session" "transaction" "statement" ];
      default = "transaction";
      description = "Pooling mode. transaction = return the server connection after each TX (recommended for query/CRUD; not for session-state-dependent clients).";
    };

    authType = mkOption {
      type = types.str;
      default = "scram-sha-256";
      description = "PgBouncer client auth type (must match the server's; userlist holds the verifiers).";
    };

    defaultPoolSize = mkOption {
      type = types.int;
      default = 20;
      description = "Server connections kept per (database, user) pair.";
    };

    maxClientConn = mkOption {
      type = types.int;
      default = 200;
      description = "Max simultaneous client connections to PgBouncer.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = cfg.databases != [];
      message = "infra.data.pgbouncer.enable is true but infra.data.pgbouncer.databases is empty — nothing would be poolable.";
    }];

    environment.etc."pgbouncer/pgbouncer.ini".text = ''
      [databases]
      ${concatMapStringsSep "\n" (db:
        "${db} = host=127.0.0.1 port=${toString cfg.backendPort} dbname=${db}"
      ) cfg.databases}

      [pgbouncer]
      listen_addr = 0.0.0.0
      listen_port = ${toString cfg.listenPort}
      auth_type = ${cfg.authType}
      # auth_query (not a static userlist of every role): PgBouncer connects as
      # the dedicated low-priv `pgbouncer_auth` role and looks each client's
      # SCRAM verifier up from pg_authid LIVE via a SECURITY-DEFINER function.
      # So when an app role's password rotates on a redeploy, nothing goes stale
      # (the old static-userlist approach silently broke auth on every rotation).
      # userlist.txt now holds ONLY pgbouncer_auth's own credential.
      auth_file = /run/pgbouncer/userlist.txt
      auth_user = pgbouncer_auth
      auth_query = SELECT uname, phash FROM public.pgbouncer_user_lookup($1)
      pool_mode = ${cfg.poolMode}
      default_pool_size = ${toString cfg.defaultPoolSize}
      max_client_conn = ${toString cfg.maxClientConn}
      min_pool_size = 2
      reserve_pool_size = 5
      server_lifetime = 3600
      server_idle_timeout = 600
      # libpq/psycopg2 send these as startup params; PgBouncer rejects unknown
      # ones by default (every connection would fail). search_path here is a ROLE
      # default (ALTER ROLE … SET search_path), so ignoring the startup copy is
      # harmless — the server-side default still applies.
      ignore_startup_parameters = extra_float_digits,search_path,options
      admin_users = postgres
    '';

    systemd.services.pgbouncer = {
      description = "PgBouncer connection pooler";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      # Provision auth_query: a dedicated low-priv `pgbouncer_auth` role + a
      # SECURITY-DEFINER lookup function in each database (owned by the postgres
      # superuser this runs as → can read pg_authid). userlist.txt then holds
      # ONLY pgbouncer_auth, with a fresh random password set on every start, so
      # it's always self-consistent and never depends on the app roles' passwords
      # (which rotate on redeploys). Idempotent + best-effort (ON_ERROR_STOP=0).
      preStart = ''
        set -u
        mkdir -p /run/pgbouncer
        PSQL="${pkgs.postgresql}/bin/psql -p ${toString cfg.backendPort} -v ON_ERROR_STOP=0"
        ADMIN=${builtins.head cfg.databases}
        PW=$(${pkgs.coreutils}/bin/tr -dc 'a-f0-9' < /dev/urandom | ${pkgs.coreutils}/bin/head -c 32)
        $PSQL -d "$ADMIN" -c "CREATE ROLE pgbouncer_auth LOGIN" 2>/dev/null || true
        $PSQL -d "$ADMIN" -c "ALTER ROLE pgbouncer_auth LOGIN PASSWORD '$PW'"
        # Lookup function in each DB (auth_query runs in the client's target DB);
        # single-quoted body avoids $-quoting / bash-expansion pitfalls.
        for db in ${lib.concatStringsSep " " cfg.databases}; do
          $PSQL -d "$db" -c "CREATE OR REPLACE FUNCTION public.pgbouncer_user_lookup(i_username text, OUT uname text, OUT phash text) RETURNS record LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT rolname, rolpassword FROM pg_authid WHERE rolname = i_username';"
          $PSQL -d "$db" -c "REVOKE ALL ON FUNCTION public.pgbouncer_user_lookup(text) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.pgbouncer_user_lookup(text) TO pgbouncer_auth; GRANT CONNECT ON DATABASE \"$db\" TO pgbouncer_auth;"
        done
        # userlist holds ONLY pgbouncer_auth — as PLAINTEXT (not the pg_authid
        # SCRAM verifier): PgBouncer needs the plaintext to authenticate its own
        # backend connection (to run auth_query). Clients still auth via SCRAM,
        # validated against the verifiers auth_query fetches live.
        printf '"pgbouncer_auth" "%s"\n' "$PW" > /run/pgbouncer/userlist.txt
        chmod 600 /run/pgbouncer/userlist.txt
      '';
      serviceConfig = {
        Type = "simple";
        User = "postgres";
        Group = "postgres";
        ExecStart = "${pkgs.pgbouncer}/bin/pgbouncer /etc/pgbouncer/pgbouncer.ini";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.tmpfiles.rules = [ "d /run/pgbouncer 0750 postgres postgres -" ];
    networking.firewall.allowedTCPPorts = [ cfg.listenPort ];
  };
}
