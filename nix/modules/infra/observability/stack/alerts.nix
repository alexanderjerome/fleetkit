# Reusable Grafana alert definitions.
#
# Each alert is a function: { ...params } -> alert rule attrset
# Compose into groups via grafana.mkAlertGroup.
#
# Usage:
#   alerts = import ./alerts.nix { inherit grafana; };
#   grafana.mkAlertGroup {
#     name = "Bitcoin Indexer Health";
#     rules = [
#       (alerts.indexerStalled { job = "bitcoin-indexer-mainnet"; network = "mainnet"; ip = "192.0.2.11"; severity = "critical"; })
#       (alerts.indexerStalled { job = "bitcoin-indexer-testnet"; network = "testnet"; ip = "192.0.2.12"; severity = "warning"; })
#     ];
#   }
#
{ grafana }:
{
  # ── Indexer stalled — no new blocks in 10 minutes ──────────────
  indexerStalled = {
    job,
    network,
    severity ? "warning",
    ip ? "",
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "indexer-stalled-${network}";
    title = "${network} Indexer Stalled";
    expr = ''increase(last_indexed_block_height{job="${job}"}[10m])'';
    noDataState = if severity == "critical" then "Alerting" else "NoData";
    inherit duration;
    annotations = {
      summary = "${network} ${job} has not indexed new blocks in 10 minutes";
      description = "Check journalctl -u bitcoin-indexer on indexer-${network}"
        + (if ip != "" then " (${ip})" else "");
    };
    labels = { inherit severity; };
  };

  # ── Service down — exporter unreachable ────────────────────────
  serviceDown = {
    job,
    service,
    severity ? "critical",
    duration ? "5m"
  }:
  grafana.mkAlertRule {
    uid = "service-down-${service}";
    title = "${service} Down";
    expr = ''up{job="${job}"}'';
    noDataState = "Alerting";
    inherit duration;
    annotations = {
      summary = "${service} exporter is unreachable";
      description = "The ${service} service (job=${job}) has been down for ${duration}";
    };
    labels = { inherit severity; };
  };

  # ── High CPU usage ─────────────────────────────────────────────
  highCpu = {
    instance,
    severity ? "warning",
    threshold ? 90,
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "high-cpu-${builtins.replaceStrings ["."] ["-"] instance}";
    title = "High CPU on ${instance}";
    expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",instance=~"${instance}"}[5m])))'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "CPU usage above ${toString threshold}% on ${instance}";
      description = "Check `fleet remote ${instance} htop` for runaway processes";
    };
    labels = { inherit severity; };
  };

  # ── High disk usage ────────────────────────────────────────────
  highDisk = {
    instance,
    mountpoint ? "/",
    severity ? "critical",
    threshold ? 90,
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "high-disk-${builtins.replaceStrings ["." "/"] ["-" "-"] instance}-${builtins.replaceStrings ["/"] ["-"] mountpoint}";
    title = "High Disk on ${instance} (${mountpoint})";
    expr = ''100 * (1 - node_filesystem_avail_bytes{instance=~"${instance}",mountpoint="${mountpoint}"} / node_filesystem_size_bytes{instance=~"${instance}",mountpoint="${mountpoint}"})'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "Disk usage above ${toString threshold}% on ${instance}:${mountpoint}";
      description = "Check `fleet remote ${instance} df -h` for disk pressure";
    };
    labels = { inherit severity; };
  };

  # ── Bitcoin node out of sync ───────────────────────────────────
  btcNodeBehind = {
    network,
    severity ? "warning",
    threshold ? 0.999,
    duration ? "30m"
  }:
  grafana.mkAlertRule {
    uid = "btc-behind-${network}";
    title = "Bitcoin ${network} Node Behind";
    expr = ''bitcoin_sync_verification_progress{job="bitcoin-${network}"}'';
    evaluator = { type = "lt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "Bitcoin ${network} node sync below ${toString (threshold * 100)}%";
      description = "Node may be stalled or catching up after restart";
    };
    labels = { inherit severity; };
  };

  # ── PostgreSQL down ────────────────────────────────────────────
  pgDown = {
    job,
    name,
    severity ? "critical",
    duration ? "5m"
  }:
  grafana.mkAlertRule {
    uid = "pg-down-${builtins.replaceStrings ["."] ["-"] name}";
    title = "${name} PostgreSQL Down";
    expr = ''pg_up{job="${job}"}'';
    noDataState = "Alerting";
    inherit duration;
    annotations = {
      summary = "PostgreSQL on ${name} is unreachable";
      description = "Check `fleet remote ${name} systemctl status postgresql`";
    };
    labels = { inherit severity; };
  };

  # ── RabbitMQ queue backlog growing ─────────────────────────────
  queueBacklog = {
    job ? "rabbitmq",
    severity ? "warning",
    threshold ? 1000,
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "rabbitmq-backlog";
    title = "RabbitMQ Queue Backlog";
    expr = ''sum(rabbitmq_queue_messages_ready{job="${job}"})'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "RabbitMQ has ${toString threshold}+ messages waiting";
      description = "Check consumer health and queue bindings";
    };
    labels = { inherit severity; };
  };

  # ── Postgres runaway/stuck transaction ─────────────────────────
  # The exact signal that would have caught the INFRA-91 backfill UPDATE
  # (a single transaction open ~20h). A long txn pins WAL + bloats tables.
  runawayTransaction = {
    threshold ? 3600,        # seconds a transaction may stay open
    severity ? "critical",
    duration ? "5m"
  }:
  grafana.mkAlertRule {
    uid = "pg-runaway-transaction";
    title = "Postgres Runaway Transaction";
    expr = ''max by (instance) (pg_stat_activity_max_tx_duration)'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "{{ $labels.instance }} has a transaction open > ${toString (builtins.div threshold 60)} min";
      description = "A long-running or stuck transaction pins WAL and bloats tables — this is what made the INFRA-91 backfill UPDATE run ~20h. Inspect pg_stat_activity ordered by xact_start on the host and terminate the pid if it is stuck.";
    };
    labels = { inherit severity; };
  };

  # ── pgbackrest WAL archiving failing — the INFRA-91 disk-fill precursor ──
  # With archive_mode=on, postgres will NOT recycle a WAL segment until
  # pgbackrest archive-push has shipped it to Garage. If archiving breaks (S3
  # unreachable, bad creds, DNS gone) failed_count climbs continuously and WAL
  # piles up until /data fills and postgres crash-loops — exactly INFRA-91
  # (3031 failures, 123 GB pinned WAL). This is the safety net INFRA-131 leaned
  # on instead of an /etc/hosts pin. Job-agnostic: fires for any postgres
  # exporter publishing pg_stat_archiver, so every monitored DB host is covered
  # and newly-scraped hosts are picked up automatically.
  pgbackrestArchiveFailing = {
    window ? "10m",
    severity ? "critical",
    duration ? "15m"
  }:
  grafana.mkAlertRule {
    uid = "pgbackrest-archive-failing";
    title = "pgbackrest WAL Archiving Failing";
    expr = ''sum by (job) (increase(pg_stat_archiver_failed_count[${window}]))'';
    evaluator = { type = "gt"; params = [ 0 ]; };
    # A genuine break retries every few seconds so failures accrue continuously;
    # requiring the condition to hold for `duration` filters brief blips the
    # archiver just retries through. NoData=OK so a scrape gap doesn't page
    # (pgDown covers an outright-down exporter).
    inherit duration;
    noDataState = "OK";
    annotations = {
      summary = "{{ $labels.job }}: pgbackrest archive-push failing for ${duration}";
      description = "WAL archiving to Garage keeps failing. With archive_mode=on, unshipped WAL cannot recycle and piles up until /data fills and postgres crash-loops (INFRA-91: 123 GB). Check `fleet remote <host> \"sudo -u postgres pgbackrest --stanza=<stanza> check\"` and S3-endpoint reachability from the DB host.";
    };
    labels = { inherit severity; };
  };

  # ── WAL directory piling up — disk-fill imminent ──────────────
  # Downstream symptom of archiving failing (or a long-open txn pinning WAL).
  # Normal WAL for these DBs is well under 1 GB (max_wal_size 8 GB on the
  # biggest); 15 GB means recycle is blocked. Fires per host (one series per
  # exporter job) with runway before /data fills.
  pgWalPileup = {
    threshold ? 15000000000,   # 15 GB
    severity ? "critical",
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "pg-wal-pileup";
    title = "Postgres WAL Pileup";
    expr = ''max by (job) (pg_wal_size_bytes)'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "{{ $labels.job }}: pg_wal is over ${toString (builtins.div threshold 1000000000)} GB";
      description = "WAL is not recycling — usually pgbackrest archive-push failing (see the archive-failing alert) or a long-open transaction pinning WAL. Left unchecked it fills /data and crash-loops postgres (INFRA-91). Check the archiver status and pg_stat_activity for an old xact_start.";
    };
    labels = { inherit severity; };
  };

  # ── PVE hypervisor API unreachable (INFRA-167) ─────────────────
  # One scrape target per cluster node (params.target = node IP), so
  # up{job="pve"} carries instance="pve-<name>" per hypervisor. A 0 means
  # that node's API :8006 is not answering (node down, pveproxy wedged) —
  # the exact "hypervisors export zero metrics" blind spot from INFRA-164.
  pveApiDown = {
    severity ? "warning",
    duration ? "5m"
  }:
  grafana.mkAlertRule {
    uid = "pve-api-down";
    title = "PVE API Unreachable";
    expr = ''up{job="pve"}'';
    noDataState = "Alerting";
    inherit duration;
    annotations = {
      summary = "{{ $labels.instance }} PVE API is not answering the exporter";
      description = "prometheus-pve-exporter could not scrape this hypervisor's API (:8006). Node down, pveproxy wedged, or the pve-exporter@pve token broken. If ALL instances are down, check prometheus-pve-exporter.service on the grafana CT. NoData also alerts — that is the pre-INFRA-167 blind spot returning.";
    };
    labels = { inherit severity; };
  };

  # ── PVE node down — cluster quorum view (INFRA-167) ────────────
  # pve_up{id="node/<name>"} comes from /cluster/status, so any reachable
  # cluster member reports EVERY node's state — max by (id) dedupes the
  # per-target copies and survives the dead node's own API being gone.
  pveNodeDown = {
    severity ? "critical",
    duration ? "5m"
  }:
  grafana.mkAlertRule {
    uid = "pve-node-down";
    title = "PVE Node Down";
    expr = ''max by (id) (pve_up{job="pve", id=~"node/.+"})'';
    noDataState = "Alerting";
    inherit duration;
    annotations = {
      summary = "{{ $labels.id }} is down per the PVE cluster quorum";
      description = "The cluster reports this hypervisor offline — every guest on it is dead. Check power/network on the node, then `pvecm status` from a surviving member.";
    };
    labels = { inherit severity; };
  };

  # ── PVE storage usage — incl. lvmthin pool data% (INFRA-167) ───
  # For lvmthin storages, PVE reports the thin pool's DATA usage as the
  # storage usage — this is the metric that hit 100% on pve-platform and
  # silently killed Prometheus/Loki for 2 days (INFRA-164). Also covers
  # dir/nfs/pbs storages (a full `local` breaks vzdump + ISO uploads).
  # max by (node, storage) dedupes the 7 per-target copies of the
  # cluster-wide /cluster/resources series.
  # NOT covered by the exporter (PVE API limitation, noted on INFRA-167):
  # thin pool METADATA% and VG-free-PE — those need a node-local textfile
  # collector (`lvs --reportformat json`) on the Debian hosts if wanted.
  pveStorageUsage = {
    threshold ? 85,
    severity ? "warning",
    duration ? "15m"
  }:
  grafana.mkAlertRule {
    uid = "pve-storage-${severity}";
    title = "PVE Storage High (${severity})";
    expr = ''100 * max by (node, storage) ((pve_disk_usage_bytes{job="pve", id=~"storage/.+"} / pve_disk_size_bytes{job="pve", id=~"storage/.+"}) * on (instance, id) group_left (node, storage) pve_storage_info)'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "{{ $labels.node }}/{{ $labels.storage }} storage above ${toString threshold}%";
      description = "For lvmthin this is the thin pool DATA usage — at 100% every write in every guest on the pool fails and services die silently (INFRA-164). Check `lvs` on the node, delete/migrate guests or grow the pool. fstrim inside guests reclaims thin blocks.";
    };
    labels = { inherit severity; };
  };

  # ── Multi-TB volume usage — % thresholds (INFRA-167) ───────────
  # The fleet-wide "under 2 GiB free" floor fires far too late at 2 TB
  # scale (by then pgbackrest fulls + PBS backups already fail). Scoped
  # to volumes >= 900 GB (s3:/data 2.15T, analytics-db:/data 1.01T,
  # btc-mainnet/libre-mainnet /data, ...) so it doesn't re-page every
  # small root disk the generic fleet-disk rules already handle.
  largeVolumeUsage = {
    threshold ? 85,
    severity ? "warning",
    duration ? "30m",
    sizeFloor ? "900e9"
  }:
  grafana.mkAlertRule {
    uid = "large-volume-usage-${severity}";
    title = "Large Volume High (${severity})";
    expr = ''(100 * (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",mountpoint!="/nix/store"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",mountpoint!="/nix/store"})) and on (instance, mountpoint) (node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",mountpoint!="/nix/store"} > ${sizeFloor})'';
    evaluator = { type = "gt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "{{ $labels.instance }}:{{ $labels.mountpoint }} above ${toString threshold}% (multi-TB volume)";
      description = "At multi-TB scale percentage headroom vanishes fast (pg-backups + pbs-chunkstore growth, INFRA-147). Run `fleet remote {{ $labels.instance }} df -h`, prune backup retention or grow the volume BEFORE the absolute-free floor trips.";
    };
    labels = { inherit severity; };
  };

  # ── Multi-TB volume fill rate — full within N days (INFRA-167) ─
  # predict_linear over a 24h window (smooths the daily pgbackrest/PBS
  # write bursts): if the linear trend crosses 0 bytes free within
  # `horizonDays`, page while there is still time to prune or grow.
  largeVolumeFillPredicted = {
    horizonDays ? 14,
    severity ? "warning",
    duration ? "2h",
    sizeFloor ? "900e9"
  }:
  grafana.mkAlertRule {
    uid = "large-volume-fill-predicted";
    title = "Large Volume Filling (predicted)";
    expr = ''predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",mountpoint!="/nix/store"}[24h], ${toString (horizonDays * 24 * 3600)}) and on (instance, mountpoint) (node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",mountpoint!="/nix/store"} > ${sizeFloor})'';
    evaluator = { type = "lt"; params = [ 0 ]; };
    inherit duration;
    noDataState = "OK";
    annotations = {
      summary = "{{ $labels.instance }}:{{ $labels.mountpoint }} full within ${toString horizonDays}d at current rate";
      description = "Linear 24h trend predicts this multi-TB volume hits 0 free within ${toString horizonDays} days. Growth drivers are usually pg-backups + pbs-chunkstore (INFRA-147). Prune retention or grow the volume now — waiting for the % thresholds costs the runway.";
    };
    labels = { inherit severity; };
  };

  # ── Memory pressure — low available memory (OOM-kill risk) ──────
  memoryPressure = {
    threshold ? 10,          # percent of RAM still available
    severity ? "warning",
    duration ? "10m"
  }:
  grafana.mkAlertRule {
    uid = "node-memory-pressure";
    title = "Memory Pressure";
    expr = ''100 * (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'';
    evaluator = { type = "lt"; params = [ threshold ]; };
    inherit duration;
    annotations = {
      summary = "{{ $labels.instance }} available memory below ${toString threshold}%";
      description = "Low memory headroom risks an OOM-kill (a 4GB work_mem on an 8GB host OOM-crashed postgres in INFRA-91). Check free -h and top memory consumers; reduce per-query memory or grow the host.";
    };
    labels = { inherit severity; };
  };
}
