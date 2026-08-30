{ config, lib, pkgs, ... }:

# pgbackrest → Garage S3 backup for fleet Postgres clusters.
#
# Per-DB-host stanza topology: each Postgres host runs pgbackrest
# locally. archive_command in postgresql.conf pushes WAL segments
# directly to S3 as they close; a systemd timer drives weekly full +
# daily differential backups. Each stanza lives under its own prefix
# inside the shared pg-backups bucket so analytics / app / timescale
# don't collide and per-DB access keys are scoped by path.
#
# Bootstrap recipe (per DB host):
#   1. Mint a Garage key + grant + save credentials to SOPS:
#        sk s3 mint-key pgbackrest-<stanza>-key pg-backups \
#          --sops-prefix integrations/pgbackrest/<stanza>
#   2. Enable on the host:
#        infra.postgresql.backup = {
#          enable = true;
#          stanza = "<stanza>";
#          s3.accessKeyIdSecret     = "integrations/pgbackrest/<stanza>/access_key_id";
#          s3.secretAccessKeySecret = "integrations/pgbackrest/<stanza>/secret_access_key";
#        };
#   3. Deploy. The pgbackrest-stanza-create oneshot fires after
#      postgresql.service and initializes the S3 repo (idempotent).
#   4. First scheduled run uploads the first full; subsequent diffs +
#      WAL archive flow continuously.
#
# Why pgbackrest over nightly pg_dump:
#   * Point-in-time recovery (~1 min RPO vs ~24h).
#   * Incremental + diff backups — 10 GB DB → ~10–25 GB of stored
#     backups instead of N × full-dump sized snapshots.
#   * Parallel restore (process-max).
#   * Native S3 backend, no shell-wrapping cron jobs.
#
# pg_dump still has its uses (schema-only snapshots, cross-version
# migrations); this module doesn't try to replace those, just adds the
# operational-backup tier we don't have today.

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.postgresql.backup;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;

  # Read PG data path + port directly from services.postgresql. Most
  # fleet DB hosts (analytics-db, app-db, timescale-db) configure
  # services.postgresql themselves rather than going through
  # infra.postgresql, so anchoring on the upstream NixOS option lets
  # this module work uniformly across both wirings.
  pgDataDir = config.services.postgresql.dataDir;
  pgPort    = config.services.postgresql.settings.port or 5432;

  # Retention profiles. The Garage layout's storage ceiling is the
  # real constraint right now (single-node, 500 GB); pgbackrest needs
  # WAL archive for the full kept-window. "lean" is the default for
  # MVP/disk-constrained ops; bump as workload + capacity grow.
  retentionProfiles = {
    lean = {
      retention-full = 1;
      windowDays = 7;
      sizeHintPerDb = "~10 GB";
      blurb = "1 full + WAL covering it (~7d window). MVP / disk-constrained default.";
    };
    standard = {
      retention-full = 2;
      windowDays = 14;
      sizeHintPerDb = "~25 GB";
      blurb = "2 fulls + WAL covering them (~14d window). Production default.";
    };
    conservative = {
      retention-full = 4;
      windowDays = 28;
      sizeHintPerDb = "~50 GB";
      blurb = "4 fulls + WAL covering them (~28d window). Bug-mitigation cushion.";
    };
  };

  selectedRetention = retentionProfiles.${cfg.retention.profile};

  # Turns `pgbackrest info --output=json` into Prometheus textfile metrics so the
  # host Alloy can scrape last-backup age/size for the Grafana dashboards. Emits
  # per (stanza,type=full|diff|incr|any): last-backup stop timestamp, DB size,
  # and compressed repo size, plus a per-stanza status + backup count.
  metricsGen = pkgs.writeText "pgbackrest-metrics.py" ''
    import sys, json
    data = json.load(sys.stdin)
    out = [
      "# HELP pgbackrest_stanza_status pgbackrest stanza status code (0=ok).",
      "# TYPE pgbackrest_stanza_status gauge",
      "# HELP pgbackrest_backup_count number of backups retained in the repo.",
      "# TYPE pgbackrest_backup_count gauge",
      "# HELP pgbackrest_last_backup_timestamp_seconds unix time the last backup finished.",
      "# TYPE pgbackrest_last_backup_timestamp_seconds gauge",
      "# HELP pgbackrest_last_backup_size_bytes logical database size of the last backup.",
      "# TYPE pgbackrest_last_backup_size_bytes gauge",
      "# HELP pgbackrest_last_backup_repo_size_bytes compressed on-repo size of the last backup.",
      "# TYPE pgbackrest_last_backup_repo_size_bytes gauge",
    ]
    def emit(metric, labels, val):
        lbl = ",".join('%s="%s"' % (k, v) for k, v in labels.items())
        out.append("%s{%s} %s" % (metric, lbl, val))
    for st in data:
        name = st.get("name", "?")
        emit("pgbackrest_stanza_status", {"stanza": name}, (st.get("status") or {}).get("code", -1))
        backups = st.get("backup") or []
        emit("pgbackrest_backup_count", {"stanza": name}, len(backups))
        if not backups:
            continue
        latest = {b.get("type", "?"): b for b in backups}
        latest["any"] = backups[-1]
        for t, b in latest.items():
            info = b.get("info") or {}
            emit("pgbackrest_last_backup_timestamp_seconds", {"stanza": name, "type": t}, (b.get("timestamp") or {}).get("stop", 0))
            emit("pgbackrest_last_backup_size_bytes", {"stanza": name, "type": t}, info.get("size", 0))
            emit("pgbackrest_last_backup_repo_size_bytes", {"stanza": name, "type": t}, (info.get("repository") or {}).get("size", 0))
    sys.stdout.write("\n".join(out) + "\n")
  '';
in
{
  options.infra.postgresql.backup = {
    enable = mkEnableOption "pgbackrest → Garage S3 backup for this PG host";

    stanza = mkOption {
      type = types.str;
      description = ''
        pgbackrest stanza name. Conventionally the short DB role
        (e.g. "analytics", "app", "timescale"). Used as the S3 prefix
        inside the shared pg-backups bucket so multiple DB hosts can
        coexist without colliding on object names.
      '';
      example = "analytics";
    };

    s3 = {
      endpoint = mkOption {
        type = types.str;
        example = "https://s3.example.lan";
        description = ''
          S3 endpoint URL. Typically an in-fleet Garage behind Caddy TLS
          (an `s3.<zone>` vhost with a step-ca cert trusted fleet-wide
          via security.pki). pgbackrest's S3 client REQUIRES
          https (it rejects an `http://` endpoint with a FormatError and
          has no plaintext mode), so we must go through the TLS front —
          Garage's direct `:3900` is plaintext and cannot be used here.

          This name resolves via the fleet's normal DNS (CoreDNS). We do
          NOT pin it in /etc/hosts: a brief CoreDNS gap (e.g. a netgate
          redeploy) is one the postgres WAL archiver simply retries and
          drains, and hardcoding the s3 host IP would silently SHADOW
          correct DNS if that host ever moved — a worse failure than the
          one it guards. The durable safeguard for a *sustained* S3/DNS
          outage (the INFRA-91 scenario, where WAL piled to 123 GB
          unnoticed) is archive-failure alerting, tracked in INFRA-133 —
          not a static hosts entry.
        '';
      };

      bucket = mkOption {
        type = types.str;
        default = "pg-backups";
        description = "Garage bucket. Provisioned by infra.garage-bootstrap on the s3 host.";
      };

      region = mkOption {
        type = types.str;
        default = "us-east-1";
        description = "S3 region label. Garage ignores it; SDK clients require some value.";
      };

      accessKeyIdSecret = mkOption {
        type = types.str;
        description = "SOPS path whose decrypted file contains the S3 access key id.";
        example = "integrations/pgbackrest/analytics/access_key_id";
      };

      secretAccessKeySecret = mkOption {
        type = types.str;
        description = "SOPS path whose decrypted file contains the S3 secret access key.";
        example = "integrations/pgbackrest/analytics/secret_access_key";
      };
    };

    retention.profile = mkOption {
      type = types.enum [ "lean" "standard" "conservative" ];
      default = "lean";
      description = ''
        Retention profile — switchable per-host without re-bootstrapping
        the stanza. Bumping the profile keeps existing backups; lowering
        it prunes on next run.

          * lean         — ${retentionProfiles.lean.blurb}
                            ${retentionProfiles.lean.sizeHintPerDb} stored per DB.
          * standard     — ${retentionProfiles.standard.blurb}
                            ${retentionProfiles.standard.sizeHintPerDb} stored per DB.
          * conservative — ${retentionProfiles.conservative.blurb}
                            ${retentionProfiles.conservative.sizeHintPerDb} stored per DB.

        WAL archive retention follows the kept fulls automatically via
        `repo1-retention-archive-type=full`.
      '';
    };

    schedule = {
      full = mkOption {
        type = types.str;
        default = "Sun 02:00";
        description = "systemd OnCalendar expression for weekly full backups.";
      };
      diff = mkOption {
        type = types.str;
        default = "Mon..Sat 02:00";
        description = ''
          systemd OnCalendar expression for differential backups.
          Each diff captures changes since the most recent full, so
          on Sunday it inherits from Saturday's full.
        '';
      };
    };
  };

  config = mkIf (config.services.postgresql.enable && cfg.enable) {
    environment.systemPackages = [ pkgs.pgbackrest ];

    # pgbackrest expects writable log + spool dirs owned by the
    # postgres user (it runs under that uid both interactively and
    # in the systemd units below).
    systemd.tmpfiles.rules = [
      "d /var/log/pgbackrest 0750 postgres postgres -"
      "d /var/spool/pgbackrest 0750 postgres postgres -"
      "d /etc/pgbackrest 0755 root root -"
    ];

    # S3 creds — postgres-owned so the archive_command (running as
    # postgres) can read /etc/pgbackrest/pgbackrest.conf and the
    # template re-renders trigger nothing here; pgbackrest reads the
    # conf on every invocation, no daemon to restart.
    sops.secrets = {
      ${cfg.s3.accessKeyIdSecret}     = sopsLib.mkSecret {} // { owner = "postgres"; };
      ${cfg.s3.secretAccessKeySecret} = sopsLib.mkSecret {} // { owner = "postgres"; };
    };

    sops.templates."pgbackrest.conf" = sopsLib.mkTemplate {
      owner = "postgres";
      mode = "0400";
      content = ''
        [global]
        repo1-type=s3
        repo1-s3-endpoint=${cfg.s3.endpoint}
        repo1-s3-bucket=${cfg.s3.bucket}
        repo1-s3-region=${cfg.s3.region}
        repo1-s3-key=${p.${cfg.s3.accessKeyIdSecret}}
        repo1-s3-key-secret=${p.${cfg.s3.secretAccessKeySecret}}
        repo1-s3-uri-style=path
        repo1-path=/${cfg.stanza}
        repo1-retention-full=${toString selectedRetention.retention-full}
        repo1-retention-archive-type=full

        # INFRA-185: garage single-object reads can stall well past the
        # 60s default while an expire's own list/delete storm is in
        # flight (Aug 2: the weekly full's expire phase died at 60s and
        # the unit sat failed). 300s lets a slow-but-progressing expire
        # degrade instead of failing the whole backup unit.
        io-timeout=300

        # Parallel compression. 4 is a sane default; bump on the
        # bigger DB hosts when CPU headroom is available.
        process-max=4
        compress-type=zst
        compress-level=3

        log-level-console=info
        log-level-file=detail
        log-path=/var/log/pgbackrest
        spool-path=/var/spool/pgbackrest

        [${cfg.stanza}]
        pg1-path=${pgDataDir}
        pg1-port=${toString pgPort}
        pg1-user=postgres
      '';
    };

    environment.etc."pgbackrest/pgbackrest.conf".source =
      config.sops.templates."pgbackrest.conf".path;

    # pgbackrest needs wal_level=replica and archive_mode=on. The
    # archive_command piggybacks on the same pgbackrest binary.
    # mkDefault so individual hosts can override (e.g. wal_level=
    # logical for hosts running logical replication).
    services.postgresql.settings = {
      wal_level        = lib.mkDefault "replica";
      archive_mode     = "on";
      archive_command  = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} archive-push %p";
      max_wal_senders  = lib.mkDefault 3;
    };

    # One-shot stanza-create on every activation. stanza-create is
    # idempotent: if the S3 repo already exists and matches the local
    # PG, it's a no-op. `pgbackrest check` after verifies the WAL
    # archive round-trip works before we declare the host healthy.
    systemd.services.pgbackrest-stanza-create = {
      description = "Initialize pgbackrest stanza ${cfg.stanza} (idempotent)";
      after = [ "postgresql.service" "pg-ensure-databases.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = ''
        set -euo pipefail
        ${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} stanza-create || true
        # `check` exercises archive-push end-to-end; if WAL isn't
        # round-tripping (bad creds, S3 unreachable, etc.) this fails
        # loud instead of silently dropping WAL on the floor.
        ${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} check
      '';
    };

    # Weekly full + Mon–Sat differential. RandomizedDelaySec smears
    # the simultaneous start time across DB hosts so we don't burst
    # the s3 host with parallel uploads.
    systemd.services.pgbackrest-full = {
      description = "pgbackrest full backup for stanza ${cfg.stanza}";
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
      };
      script = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} --type=full backup";
    };

    systemd.timers.pgbackrest-full = {
      description = "Weekly full backup timer for stanza ${cfg.stanza}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule.full;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    systemd.services.pgbackrest-diff = {
      description = "pgbackrest differential backup for stanza ${cfg.stanza}";
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
      };
      script = "${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} --type=diff backup";
    };

    systemd.timers.pgbackrest-diff = {
      description = "Daily differential backup timer for stanza ${cfg.stanza}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule.diff;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    # ── Backup metrics → Prometheus (last-backup age + size on Grafana) ──
    # A timer renders `pgbackrest info --output=json` into a textfile the host
    # Alloy scrapes via the node_exporter textfile collector. World-readable so
    # the (different) alloy user can read it.
    systemd.services.pgbackrest-metrics = {
      description = "Export pgbackrest backup status as Prometheus metrics for stanza ${cfg.stanza}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        StateDirectory = "pgbackrest-metrics";
        StateDirectoryMode = "0755";
        UMask = "0022";
      };
      script = ''
        set -euo pipefail
        dir=/var/lib/pgbackrest-metrics
        ${pkgs.pgbackrest}/bin/pgbackrest --stanza=${cfg.stanza} --output=json info \
          | ${pkgs.python3}/bin/python3 ${metricsGen} > "$dir/pgbackrest.prom.tmp"
        mv "$dir/pgbackrest.prom.tmp" "$dir/pgbackrest.prom"
      '';
    };
    systemd.timers.pgbackrest-metrics = {
      description = "Refresh pgbackrest Prometheus metrics for stanza ${cfg.stanza}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "5min";
        AccuracySec = "1min";
      };
    };

    # Alloy scrapes the textfile (node_exporter textfile collector only) and
    # forwards to the same remote_write the other host exporters use.
    infra.alloy.extraConfig = ''
      prometheus.exporter.unix "pgbackrest_textfile" {
        set_collectors = ["textfile"]
        textfile {
          directory = "/var/lib/pgbackrest-metrics"
        }
      }
      prometheus.scrape "pgbackrest_metrics" {
        targets    = prometheus.exporter.unix.pgbackrest_textfile.targets
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "5m"
        job_name   = "pgbackrest-metrics"
      }
    '';
  };
}
