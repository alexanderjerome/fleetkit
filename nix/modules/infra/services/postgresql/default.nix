{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types concatStringsSep
    mapAttrsToList;
  cfg = config.infra.postgresql;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;

  # Sub-module type for each managed database.
  databaseType = types.submodule {
    options = {
      user = mkOption {
        type = types.str;
        example = "appuser";
        description = "Role name (created with LOGIN and DB ownership).";
      };
      passwordSecret = mkOption {
        type = types.str;
        example = "dbs/app/password";
        description = "Sops key path whose decrypted file contains the role password.";
      };
    };
  };

  # Resolve the decrypted file path for a sops secret key.
  secretPath = key: config.sops.secrets.${key}.path;
in
{
  imports = [
    # Backup sub-module: pgbackrest → Garage S3. Opt-in per-host via
    # infra.postgresql.backup.enable; inert until enabled.
    ./pgbackrest.nix
    # pgweb read-only export: advertises databases to the fleet pgweb
    # LXC + provisions the read-only `pgweb` role (INFRA-42). Inert
    # while pgwebAccess.databases is empty.
    ./pgweb-access.nix
  ];

  options.infra.postgresql = {
    enable = mkEnableOption "PostgreSQL server for platform services";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/postgresql/16";
      description = "Directory for PostgreSQL data.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_16;
      defaultText = lib.literalExpression "pkgs.postgresql_16";
      description = "PostgreSQL package to use.";
    };

    tcpPort = mkOption {
      type = types.port;
      default = 5432;
      description = "TCP port PostgreSQL listens on.";
    };

    maxConnections = mkOption {
      type = types.int;
      default = 100;
      description = "Maximum number of concurrent connections.";
    };

    sharedBuffers = mkOption {
      type = types.str;
      default = "1GB";
      description = "Shared buffer pool size.";
    };

    effectiveCacheSize = mkOption {
      type = types.str;
      default = "3GB";
      description = "Planner estimate of OS file cache size.";
    };

    workMem = mkOption {
      type = types.str;
      default = "10MB";
      description = "Memory per sort/hash operation.";
    };

    maintenanceWorkMem = mkOption {
      type = types.str;
      default = "256MB";
      description = "Memory for maintenance operations (VACUUM, CREATE INDEX).";
    };

    walBuffers = mkOption {
      type = types.str;
      default = "16MB";
      description = "WAL buffer size.";
    };

    allowedSubnets = mkOption {
      type = types.listOf types.str;
      default = lib.optional (config.fleet.settings.network.lanCidr != null)
        config.fleet.settings.network.lanCidr;
      defaultText = lib.literalExpression "[ config.fleet.settings.network.lanCidr ]";
      example = [ "192.0.2.0/24" ];
      description = "Subnets allowed to connect via TCP. Defaults to the fleet LAN CIDR when fleet.settings.network.lanCidr is set, otherwise [] (local connections only).";
    };

    authMethod = mkOption {
      type = types.enum [ "scram-sha-256" "md5" "trust" ];
      default = "scram-sha-256";
      description = "Authentication method for network connections.";
    };

    databases = mkOption {
      type = types.attrsOf databaseType;
      default = {};
      description = ''
        Databases to provision declaratively. Each key is the database name.
        Roles are created with login privileges and passwords set from sops secrets.
        The role is granted ownership of its database.
      '';
      example = {
        komodo = { user = "komodo"; passwordSecret = "komodo/db_password"; };
      };
    };
  };

  config = mkIf cfg.enable {
    # Declare sops secrets: superuser + each managed database password.
    sops.secrets = {
      "dbs/auth/superuser_password" = sopsLib.mkSecret {
        restartUnits = [ "postgresql.service" ];
      };
    } // builtins.listToAttrs (mapAttrsToList (_: dbCfg: {
      name = dbCfg.passwordSecret;
      value = sopsLib.mkSecret {
        restartUnits = [ "pg-ensure-databases.service" ];
      } // { owner = "postgres"; };
    }) cfg.databases);

    sops.templates."pg-init-script" = sopsLib.mkTemplate {
      content = "ALTER USER postgres PASSWORD '${p."dbs/auth/superuser_password"}';\n";
      owner = "postgres";
      mode = "0400";
    };

    services.postgresql = {
      initialScript = config.sops.templates."pg-init-script".path;
      enable = true;
      package = cfg.package;
      dataDir = cfg.dataDir;
      enableTCPIP = true;

      authentication = concatStringsSep "\n" ([
        "# TYPE  DATABASE  USER  ADDRESS         METHOD"
        "local   all       all                   peer"
      ] ++ map (subnet:
        "host    all       all   ${subnet}    ${cfg.authMethod}"
      ) cfg.allowedSubnets);

      settings = {
        max_connections = cfg.maxConnections;
        shared_buffers = cfg.sharedBuffers;
        effective_cache_size = cfg.effectiveCacheSize;
        work_mem = cfg.workMem;
        maintenance_work_mem = cfg.maintenanceWorkMem;
        wal_buffers = cfg.walBuffers;
        port = cfg.tcpPort;
      };

      # Declarative database creation (idempotent).
      ensureDatabases = builtins.attrNames cfg.databases;

      # Declarative role creation (idempotent, but cannot set passwords).
      ensureUsers = mapAttrsToList (dbName: dbCfg: {
        name = dbCfg.user;
        ensureDBOwnership = true;
      }) cfg.databases;
    };

    # Post-start service that sets role passwords from sops-decrypted files.
    # Runs after postgresql.service on every activation to keep passwords in sync.
    systemd.services.pg-ensure-databases = mkIf (cfg.databases != {}) {
      description = "Set PostgreSQL role passwords from sops secrets";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = concatStringsSep "\n" (mapAttrsToList (_: dbCfg: ''
        # The role is created by services.postgresql.ensureUsers, which can
        # still be racing this unit on a fresh first boot (After=postgresql
        # only orders against the service being active, not against the
        # ensure step completing). Without this wait the ALTER hits
        # `role "${dbCfg.user}" does not exist`, the oneshot fails, and the
        # password is never set — so a from-scratch deploy leaves the role
        # with a NULL password until the next activation. Wait for the role
        # to exist (idempotent no-op once it does) before setting it.
        for _ in $(seq 1 60); do
          if [ "$(${cfg.package}/bin/psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${dbCfg.user}'")" = "1" ]; then
            break
          fi
          sleep 1
        done
        ${cfg.package}/bin/psql -c "ALTER ROLE ${dbCfg.user} WITH PASSWORD '$(cat ${secretPath dbCfg.passwordSecret})';"
      '') cfg.databases);
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 postgres postgres -"
    ];

    networking.firewall.allowedTCPPorts = [ cfg.tcpPort ];

    # Advertise declaratively-managed databases to the fleet pgweb
    # instance (INFRA-42). Hosts whose databases exist only at runtime
    # (pgbackrest restores) append names in their host files.
    infra.postgresql.pgwebAccess.databases = builtins.attrNames cfg.databases;
    infra.postgresql.pgwebAccess.port = lib.mkDefault cfg.tcpPort;
  };
}
