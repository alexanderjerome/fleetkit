# Reusable Grafana panel definitions.
#
# Each panel is a function: { gridPos, id, ... overrides } -> panel attrset
# Organised by domain. Drop them into any dashboard's panels list.
#
# Usage:
#   panels = import ./panels.nix { inherit grafana; };
#   panels.infra.cpuUsage { instance = "btc-.*"; gridPos = grafana.pos.half 0 5; id = 10; }
#
{ grafana }:
{
  # ═══════════════════════════════════════════════════════════════
  #  Infrastructure — CPU, Memory, Disk, Network (5-9 dashboards)
  # ═══════════════════════════════════════════════════════════════
  infra = {

    cpuUsage = {
      gridPos,
      id,
      instance ? ".*",
      job ? "integrations/node_exporter",
      title ? "CPU Usage"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 20;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green"; value = null; }
          { color = "red"; value = 90; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",job="${job}",instance=~"${instance}"}[5m]))'';
        })
      ];
    };

    memoryUsage = {
      gridPos,
      id,
      instance ? ".*",
      job ? "integrations/node_exporter",
      title ? "Memory Usage"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 20;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green"; value = null; }
          { color = "red"; value = 90; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (node_memory_MemAvailable_bytes{job="${job}",instance=~"${instance}"} / node_memory_MemTotal_bytes{job="${job}",instance=~"${instance}"})'';
        })
      ];
    };

    diskUsage = {
      gridPos,
      id,
      instance ? ".*",
      job ? "integrations/node_exporter",
      mountpoint ? "/",
      title ? "Disk Usage (${mountpoint})"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 20;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green"; value = null; }
          { color = "red"; value = 90; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (node_filesystem_avail_bytes{job="${job}",instance=~"${instance}",mountpoint="${mountpoint}"} / node_filesystem_size_bytes{job="${job}",instance=~"${instance}",mountpoint="${mountpoint}"})'';
          legendFormat = "{{instance}} ${mountpoint}";
        })
      ];
    };

    networkIO = {
      gridPos,
      id,
      instance ? ".*",
      job ? "integrations/node_exporter",
      device ? "eth0",
      deviceMatch ? null,   # Override with a full PromQL matcher, e.g. ''device!="lo"''
      title ? "Network I/O"
    }:
    let
      matcher = if deviceMatch != null then deviceMatch else ''device="${device}"'';
    in
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "Bps";
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget {
          expr = ''rate(node_network_receive_bytes_total{job="${job}",instance=~"${instance}",${matcher}}[5m])'';
          legendFormat = "{{instance}} rx {{device}}";
        })
        (grafana.mkPromTarget {
          expr = ''rate(node_network_transmit_bytes_total{job="${job}",instance=~"${instance}",${matcher}}[5m])'';
          legendFormat = "{{instance}} tx {{device}}";
          refId = "B";
        })
      ];
    };

    serviceStatus = {
      gridPos,
      id,
      expr,
      title ? "Service Status"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      thresholds = grafana.thresholds.binary;
      colorMode = "background";
      graphMode = "none";
      mappings = [{
        options = {
          "0" = { color = "red"; text = "DOWN"; };
          "1" = { color = "green"; text = "UP"; };
        };
        type = "value";
      }];
      targets = [
        (grafana.mkPromTarget { inherit expr; legendFormat = ""; })
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  PostgreSQL — shared between analytics-db, timescale-db
  # ═══════════════════════════════════════════════════════════════
  db = {

    connectionsStat = {
      gridPos,
      id,
      job,
      title ? "Active Connections"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green"; value = null; }
          { color = "yellow"; value = 50; }
          { color = "red"; value = 150; }
        ];
      };
      targets = [
        (grafana.mkPromTarget { expr = ''sum(pg_stat_activity_count{job="${job}",state="active"})''; legendFormat = "active"; })
      ];
    };

    sizeStat = {
      gridPos,
      id,
      job,
      title ? "Database Size"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "decbytes";
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum(pg_database_size_bytes{job="${job}",datname!~"template.*|postgres"})'';
          legendFormat = "";
        })
      ];
    };

    sizeOverTime = {
      gridPos,
      id,
      job,
      drawStyle ? "line",
      stacking ? "none",
      title ? "Database Sizes"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id drawStyle stacking;
      unit = "decbytes";
      fillOpacity = if drawStyle == "bars" then 80 else 20;
      targets = [
        (grafana.mkPromTarget {
          expr = ''pg_database_size_bytes{job="${job}",datname!~"template.*|postgres"}'';
          legendFormat = "{{datname}}";
        })
      ];
    };

    connectionsGauge = {
      gridPos,
      id,
      job,
      title ? "Active Connections"
    }:
    grafana.mkGaugePanel {
      inherit title gridPos id;
      unit = "none";
      min = 0;
      max = 200;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green";  value = null; }
          { color = "yellow"; value = 50; }
          { color = "red";    value = 100; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''pg_stat_activity_count{job="${job}"} or pg_stat_database_numbackends{job="${job}"}'';
          legendFormat = "{{datname}}";
        })
      ];
    };

    connectionsOverTime = {
      gridPos,
      id,
      job,
      title ? "Connections Per Database"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum by (datname) (pg_stat_activity_count{job="${job}",datname!~"template.*|postgres|",state!=""})'';
          legendFormat = "{{datname}}";
        })
      ];
    };

    transactionRate = {
      gridPos,
      id,
      job,
      title ? "Transaction Rate"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "ops";
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget {
          expr = ''rate(pg_stat_database_xact_commit{job="${job}",datname!~"template.*|postgres"}[5m])'';
          legendFormat = "{{datname}} commits";
        })
        (grafana.mkPromTarget {
          expr = ''rate(pg_stat_database_xact_rollback{job="${job}",datname!~"template.*|postgres"}[5m])'';
          legendFormat = "{{datname}} rollbacks";
          refId = "B";
        })
      ];
    };

    tupleOperations = {
      gridPos,
      id,
      job,
      title ? "Tuple Operations"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "ops";
      fillOpacity = 10;
      targets = [
        (grafana.mkPromTarget { expr = ''rate(pg_stat_database_tup_inserted{job="${job}"}[5m])''; legendFormat = "inserts"; })
        (grafana.mkPromTarget { expr = ''rate(pg_stat_database_tup_updated{job="${job}"}[5m])''; legendFormat = "updates"; refId = "B"; })
        (grafana.mkPromTarget { expr = ''rate(pg_stat_database_tup_deleted{job="${job}"}[5m])''; legendFormat = "deletes"; refId = "C"; })
        (grafana.mkPromTarget { expr = ''rate(pg_stat_database_tup_fetched{job="${job}"}[5m])''; legendFormat = "fetches"; refId = "D"; })
      ];
    };

    pgStatus = {
      gridPos,
      id,
      job,
      title ? "PostgreSQL Status"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      thresholds = grafana.thresholds.binary;
      colorMode = "background";
      graphMode = "none";
      mappings = [{
        options = {
          "0" = { color = "red"; text = "DOWN"; };
          "1" = { color = "green"; text = "UP"; };
        };
        type = "value";
      }];
      targets = [
        (grafana.mkPromTarget { expr = ''pg_up{job="${job}"}''; legendFormat = ""; })
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  API / HTTP services — request rate, latency, errors
  # ═══════════════════════════════════════════════════════════════
  api = {

    requestRate = {
      gridPos,
      id,
      job,
      title ? "Request Rate",
      groupBy ? "handler"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "reqps";
      fillOpacity = 20;
      stacking = "normal";
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum by (${groupBy}) (rate(http_requests_total{job=~"${job}"}[5m]))'';
          legendFormat = "{{${groupBy}}}";
        })
      ];
    };

    latencyPercentiles = {
      gridPos,
      id,
      job ? "",
      metric ? "http_request_duration_seconds_bucket",
      labels ? "",
      title ? "Request Latency (p50/p95/p99)"
    }:
    let
      filter = if job != "" then ''job=~"${job}"'' else labels;
    in
    grafana.mkPercentilePanel {
      inherit title gridPos id;
      inherit metric;
      labels = filter;
      unit = "s";
    };

    errorRate = {
      gridPos,
      id,
      job,
      title ? "Error Rate"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "percent";
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green"; value = null; }
          { color = "yellow"; value = 1; }
          { color = "red"; value = 5; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''100 * sum(rate(http_requests_total{job=~"${job}",status=~"[45].."}[5m])) / clamp_min(sum(rate(http_requests_total{job=~"${job}"}[5m])), 1)'';
          legendFormat = "";
        })
      ];
    };

    inFlightRequests = {
      gridPos,
      id,
      job,
      title ? "In-Progress Requests"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      thresholds = grafana.thresholds.queue;
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum(http_requests_in_progress{job=~"${job}"})'';
          legendFormat = "In-flight";
        })
      ];
    };

    topEndpoints = {
      gridPos,
      id,
      job,
      limit ? 10,
      title ? "Top Endpoints by Request Count"
    }:
    grafana.mkTablePanel {
      inherit title gridPos id;
      sortBy = [{ desc = true; displayName = "Requests"; }];
      targets = [
        (grafana.mkPromTarget {
          expr = ''topk(${toString limit}, sum by (handler) (increase(http_requests_total{job=~"${job}"}[$__range])))'';
          format = "table";
          instant = true;
          legendFormat = "";
        })
      ];
      transformations = [
        {
          id = "organize";
          options = {
            excludeByName = { Time = true; "__name__" = true; job = true; };
            renameByName = { "Value" = "Requests"; handler = "Endpoint"; };
          };
        }
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  Bitcoin Core nodes — block height, sync, peers, disk
  # ═══════════════════════════════════════════════════════════════
  bitcoin = {

    blockHeight = {
      gridPos,
      id,
      title ? "Block Height"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "locale";
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_sync_blocks"; legendFormat = "{{job}}"; })
      ];
    };

    syncProgress = {
      gridPos,
      id,
      title ? "Sync Progress"
    }:
    grafana.mkGaugePanel {
      inherit title gridPos id;
      decimals = 4;
      thresholds = grafana.thresholds.health;
      targets = [
        (grafana.mkPromTarget {
          expr = "bitcoin_sync_presync_progress > 0 or bitcoin_sync_verification_progress";
          legendFormat = "{{job}}";
        })
      ];
    };

    blockchainSize = {
      gridPos,
      id,
      title ? "Blockchain Size"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "decbytes";
      decimals = 2;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_sync_size_on_disk"; legendFormat = "{{job}}"; })
      ];
    };

    peers = {
      gridPos,
      id,
      title ? "Peers"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_peers"; legendFormat = "{{job}}"; })
      ];
    };

    blocksVsHeaders = {
      gridPos,
      id,
      title ? "Blocks vs Headers"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "locale";
      decimals = 0;
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_sync_blocks"; legendFormat = "{{job}} blocks"; })
        (grafana.mkPromTarget { expr = "bitcoin_sync_headers"; legendFormat = "{{job}} headers"; refId = "B"; })
        (grafana.mkPromTarget { expr = "bitcoin_sync_presync_headers"; legendFormat = "{{job}} presync headers"; refId = "C"; })
      ];
    };

    verificationProgress = {
      gridPos,
      id,
      title ? "Verification Progress Over Time"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "percentunit";
      decimals = 4;
      min = 0; max = 1;
      fillOpacity = 20;
      lineWidth = 2;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_sync_verification_progress"; legendFormat = "{{job}} verification"; })
        (grafana.mkPromTarget { expr = "bitcoin_sync_presync_progress"; legendFormat = "{{job}} header presync"; refId = "B"; })
      ];
    };

    sizeOverTime = {
      gridPos,
      id,
      title ? "Blockchain Size Over Time"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "decbytes";
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_size_on_disk"; legendFormat = "{{job}}"; })
      ];
    };

    peersOverTime = {
      gridPos,
      id,
      title ? "Peer Count Over Time"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      fillOpacity = 20;
      targets = [
        (grafana.mkPromTarget { expr = "bitcoin_peers"; legendFormat = "{{job}}"; })
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  Blockchain indexers — block processing, sync status, runes
  # ═══════════════════════════════════════════════════════════════
  indexer = let
    # Resolve a filter string from either `job` (exact) or `jobRegex` (regex).
    mkJobFilter = { job ? null, jobRegex ? null }:
      if jobRegex != null then ''job=~"${jobRegex}"''
      else if job != null then ''job="${job}"''
      else throw "indexer panel requires `job` or `jobRegex`";
  in {

    lastIndexedBlock = {
      gridPos,
      id,
      job ? null,
      jobRegex ? null,
      title ? "Current Block Height"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "locale";
      targets = [
        (grafana.mkPromTarget {
          expr = ''last_indexed_block_height{${mkJobFilter { inherit job jobRegex; }}}'';
          legendFormat = "{{job}}";
        })
      ];
    };

    blockHeightOverTime = {
      gridPos,
      id,
      job ? null,
      jobRegex ? null,
      title ? "Block Height Over Time"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "locale";
      fillOpacity = 10;
      lineWidth = 2;
      spanNulls = true;
      targets = [
        (grafana.mkPromTarget {
          expr = ''last_indexed_block_height{${mkJobFilter { inherit job jobRegex; }}}'';
          legendFormat = "{{job}}";
        })
      ];
    };

    syncPercent = {
      gridPos,
      id,
      job,
      targetBlocks,
      title ? "Sync Progress"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "percent";
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "red";    value = null; }
          { color = "orange"; value = 50; }
          { color = "yellow"; value = 90; }
          { color = "green";  value = 99; }
        ];
      };
      targets = [
        (grafana.mkPromTarget {
          expr = ''last_indexed_block_height{job="${job}"} / ${toString targetBlocks} * 100'';
          legendFormat = "";
        })
      ];
    };

    processingRate = {
      gridPos,
      id,
      job ? null,
      jobRegex ? null,
      title ? "Blocks per Second"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      unit = "ops";
      fillOpacity = 10;
      lineWidth = 2;
      spanNulls = true;
      targets = [
        (grafana.mkPromTarget {
          expr = ''rate(last_indexed_block_height{${mkJobFilter { inherit job jobRegex; }}}[5m])'';
          legendFormat = "{{job}}";
        })
      ];
    };

    totalRunesIndexed = {
      gridPos,
      id,
      job ? null,
      jobRegex ? null,
      title ? "Total Runes Indexed"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "locale";
      targets = [
        (grafana.mkPromTarget {
          expr = ''last_indexed_rune_number{${mkJobFilter { inherit job jobRegex; }}}'';
          legendFormat = "{{job}}";
        })
      ];
    };

    # Rune operations per block (etching/mint/edict/cenotaph). The indexer
    # exports these as plain gauges (runes_<op>_operations_per_block) — the
    # current per-block operation count — NOT a summary, so there is no
    # _sum/_count pair to rate(). Plot the gauge directly.
    runeOperationRate = {
      gridPos,
      id,
      operation,      # "etching", "mint", "edict", "cenotaph"
      job ? null,
      jobRegex ? null,
      title ? null
    }:
    let
      filter = mkJobFilter { inherit job jobRegex; };
      metric = "runes_${operation}_operations_per_block";
    in
    grafana.mkTimeseriesPanel {
      inherit gridPos id;
      title = if title != null then title else "Rune ${operation} ops/block";
      unit = "short";
      fillOpacity = 10;
      spanNulls = true;
      targets = [
        (grafana.mkPromTarget {
          expr = ''${metric}{${filter}}'';
          legendFormat = "{{job}}";
        })
      ];
    };

    # Performance histogram (block processing, db write, computation, parsing).
    # Pass metricBase like "runes_block_processing_time" or "rune_db_write_time".
    performanceTime = {
      gridPos,
      id,
      metricBase,
      job ? null,
      jobRegex ? null,
      title,
      unit ? "ms",
      percentiles ? [ 0.5 0.95 ]
    }:
    let
      filter = mkJobFilter { inherit job jobRegex; };
      refIds = [ "A" "B" "C" "D" ];
    in
    grafana.mkTimeseriesPanel {
      inherit title gridPos id unit;
      fillOpacity = 10;
      spanNulls = true;
      legendCalcs = [ "mean" "max" ];
      targets = builtins.map (i:
        grafana.mkPromTarget {
          expr = ''histogram_quantile(${toString (builtins.elemAt percentiles i)}, rate(${metricBase}_bucket{${filter}}[5m]))'';
          legendFormat = "{{job}} p${toString (builtins.floor (builtins.elemAt percentiles i * 100))}";
          refId = builtins.elemAt refIds i;
        }
      ) (builtins.genList (i: i) (builtins.length percentiles));
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  TimescaleDB-specific (hypertables, compression, continuous aggregates)
  # ═══════════════════════════════════════════════════════════════
  timescale = {

    hypertables = {
      gridPos,
      id,
      job ? "timescale-db",
      title ? "Hypertables"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      graphMode = "none";
      targets = [
        (grafana.mkPromTarget {
          expr = ''timescaledb_hypertable_count{job="${job}"} or count(pg_statio_user_tables_idx_blks_hit{job="${job}",schemaname="_timescaledb_internal"})'';
          legendFormat = "count";
        })
      ];
    };

    compressionRatio = {
      gridPos,
      id,
      job ? "timescale-db",
      title ? "Chunk Compression Ratio"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "percentunit";
      thresholds = grafana.thresholds.health;
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (timescaledb_compressed_size_bytes{job="${job}"} / clamp_min(timescaledb_uncompressed_size_bytes{job="${job}"}, 1))'';
          legendFormat = "ratio";
        })
      ];
    };

    continuousAggregateRefresh = {
      gridPos,
      id,
      job ? "timescale-db",
      title ? "Continuous Aggregate Last Refresh"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      unit = "dateTimeFromNow";
      graphMode = "none";
      mappings = [
        { options = { "0" = { color = "red"; text = "Stale"; }; }; type = "value"; }
      ];
      targets = [
        (grafana.mkPromTarget {
          expr = ''timescaledb_continuous_aggregate_last_refresh_time{job="${job}"} * 1000'';
          legendFormat = "{{view_name}}";
        })
      ];
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  RabbitMQ
  # ═══════════════════════════════════════════════════════════════
  rabbitmq = {

    connections = {
      gridPos,
      id,
      job ? "rabbitmq",
      title ? "Connections"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green";  value = null; }
          { color = "yellow"; value = 50; }
          { color = "red";    value = 100; }
        ];
      };
      targets = [
        (grafana.mkPromTarget { expr = ''rabbitmq_connections{job="${job}"}''; legendFormat = "Connections"; })
      ];
    };

    channels = {
      gridPos,
      id,
      job ? "rabbitmq",
      title ? "Channels"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      targets = [
        (grafana.mkPromTarget { expr = ''rabbitmq_channels{job="${job}"}''; legendFormat = "Channels"; })
      ];
    };

    queueCount = {
      gridPos,
      id,
      job ? "rabbitmq",
      title ? "Queue Count"
    }:
    grafana.mkStatPanel {
      inherit title gridPos id;
      graphMode = "none";
      targets = [
        (grafana.mkPromTarget { expr = ''rabbitmq_queues{job="${job}"}''; legendFormat = "Queues"; })
      ];
    };

    queueDepth = {
      gridPos,
      id,
      job ? "rabbitmq",
      title ? "Queue Depth"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      fillOpacity = 20;
      stacking = "normal";
      targets = [
        (grafana.mkPromTarget { expr = ''rabbitmq_queue_messages_ready{job="${job}"}''; legendFormat = "Ready"; })
        (grafana.mkPromTarget { expr = ''rabbitmq_queue_messages_unacked{job="${job}"}''; legendFormat = "Unacked"; refId = "B"; })
      ];
    };

    messageThroughput = {
      gridPos,
      id,
      job ? "rabbitmq",
      title ? "Message Throughput"
    }:
    grafana.mkTimeseriesPanel {
      inherit title gridPos id;
      fillOpacity = 15;
      targets = [
        (grafana.mkPromTarget { expr = ''rate(rabbitmq_global_messages_received_total{job="${job}"}[5m])''; legendFormat = "Received"; })
        (grafana.mkPromTarget { expr = ''rate(rabbitmq_global_messages_delivered_total{job="${job}"}[5m])''; legendFormat = "Delivered"; refId = "B"; })
      ];
    };
  };
}
