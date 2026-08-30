# Build Infrastructure — Nix cache durability + Harmonia binary cache + Nix store.
#
# Everything on the builder host (nix-builder, CT101) for building and
# distributing Nix artifacts:
#   - Harmonia (:5000)  — serves the local /nix/store as the fleet's LIVE
#     binary cache; every fleet host pulls from it (cache.url substituter).
#   - atticd (:8080 → Garage S3) — pushes each local build's closure to
#     Garage for OFF-HOST durability, so the cache survives loss of the
#     builder. Populated by nix.settings.post-build-hook.
#
# Hydra CI was decommissioned (infra.build.hydra is off) — its dashboard
# rows were removed in INFRA-128 since the metrics no longer exist. Recover
# them from git history if Hydra is ever revived (scrape config still lives
# in nix/modules/builder/hydra.nix).
#
{ grafana, panels }:
let
  # node_exporter labels the builder host by hostname, not IP.
  builderInst = "nix-builder";
  # Harmonia is scraped as its own job (single instance 127.0.0.1:5000);
  # select it by job, not by host instance.
  harmoniaSel = ''job="harmonia"'';
in
grafana.mkDashboard {
  title = "Build Infrastructure";
  uid = "build-infra";
  tags = [ "harmonia" "atticd" "binary-cache" "s3" "nix" ];
  refresh = "30s";
  timeFrom = "now-6h";
  panels = [

    # ═══ Nix Cache Durability (atticd → Garage S3) ═══════════════════
    # atticd is the off-host durability layer. If it is DOWN the fleet keeps
    # building and pulling via Harmonia, but new build closures are NOT
    # backed up to Garage — losing the builder would lose the cache.
    (grafana.mkRow { title = "Nix Cache Durability (atticd → Garage S3)"; y = 0; id = 1; })
    (panels.infra.serviceStatus {
      expr = ''up{job="atticd"}'';
      gridPos = { h = 4; w = 6; x = 0; y = 1; };
      id = 2;
      title = "atticd Push Cache";
    })
    (panels.infra.serviceStatus {
      expr = ''up{job="garage"}'';
      gridPos = { h = 4; w = 6; x = 6; y = 1; };
      id = 3;
      title = "Garage S3 Backend";
    })
    # Garage disk fill — the S3 backend stores BOTH the atticd Nix cache and
    # media-service uploads, so a full Garage breaks pushes and uploads. Same
    # early-warning role the datastore panels play for PVE thinpools.
    (grafana.mkGaugePanel {
      title = "Garage Data Fill";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = grafana.thresholds.usage;
      gridPos = { h = 4; w = 6; x = 12; y = 1; };
      id = 5;
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (garage_local_disk_avail{volume="data"} / garage_local_disk_total{volume="data"})'';
          legendFormat = "data";
        })
      ];
    })
    (grafana.mkGaugePanel {
      title = "Garage Metadata Fill";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = grafana.thresholds.usage;
      gridPos = { h = 4; w = 6; x = 18; y = 1; };
      id = 6;
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (garage_local_disk_avail{volume="metadata"} / garage_local_disk_total{volume="metadata"})'';
          legendFormat = "metadata";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Garage S3 Disk Fill Over Time";
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 10;
      gridPos = { h = 6; w = 12; x = 0; y = 5; };
      id = 7;
      targets = [
        (grafana.mkPromTarget {
          expr = ''1 - (garage_local_disk_avail / garage_local_disk_total)'';
          legendFormat = "{{volume}}";
        })
      ];
    })
    (grafana.mkTextPanel {
      title = "About this layer";
      content = ''
        **Harmonia** (below) is the *live* fleet cache — every host pulls from it.
        **atticd** pushes build closures to **Garage S3** for off-host durability;
        Garage also backs media-service uploads.

        If **atticd** is DOWN the fleet still builds/pulls via Harmonia, but new
        closures aren't backed up — losing `nix-builder` would lose the cache.
        Fix: re-key atticd against Garage (`ansible/playbooks/attic-rebootstrap.yml`).
      '';
      gridPos = { h = 6; w = 12; x = 12; y = 5; };
      id = 4;
    })

    # ═══ Binary Cache (Harmonia) ═════════════════════════════════════
    (grafana.mkRow { title = "Binary Cache — Harmonia (live fleet cache)"; y = 11; id = 20; })
    (grafana.mkTimeseriesPanel {
      title = "Cache Requests / sec";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 7; w = 8; x = 0; y = 12; };
      id = 21;
      targets = [
        (grafana.mkPromTarget { expr = ''sum(rate(harmonia_http_requests_total{${harmoniaSel}}[5m]))''; legendFormat = "requests"; })
      ];
    })
    (grafana.mkGaugePanel {
      title = "Cache Hit Rate (2xx %)";
      unit = "percent"; min = 0; max = 100;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "red";    value = null; }
          { color = "yellow"; value = 80; }
          { color = "green";  value = 95; }
        ];
      };
      gridPos = { h = 7; w = 8; x = 8; y = 12; };
      id = 22;
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum(rate(harmonia_http_requests_total{${harmoniaSel},status=~"2.."}[5m])) / sum(rate(harmonia_http_requests_total{${harmoniaSel}}[5m])) * 100'';
          legendFormat = "hit rate";
        })
      ];
    })
    (grafana.mkStatPanel {
      title = "Active Connections";
      gridPos = { h = 3; w = 4; x = 16; y = 12; };
      id = 23;
      targets = [ (grafana.mkPromTarget { expr = ''harmonia_daemon_active_connections{${harmoniaSel}}''; legendFormat = "active"; }) ];
    })
    (grafana.mkStatPanel {
      title = "Idle Connections";
      gridPos = { h = 3; w = 4; x = 20; y = 12; };
      id = 24;
      targets = [ (grafana.mkPromTarget { expr = ''harmonia_daemon_idle_connections{${harmoniaSel}}''; legendFormat = "idle"; }) ];
    })
    (grafana.mkPercentilePanel {
      title = "Cache Request Latency (p50 / p95)";
      metric = "harmonia_http_request_duration_seconds_bucket";
      labels = harmoniaSel;
      percentiles = [ 0.5 0.95 ];
      gridPos = { h = 4; w = 8; x = 16; y = 15; };
      id = 25;
    })

    # ═══ Nix Store ═══════════════════════════════════════════════════
    (grafana.mkRow { title = "Nix Store"; y = 19; id = 30; })
    (grafana.mkGaugePanel {
      title = "Root Filesystem Usage";
      unit = "percent"; min = 0; max = 100;
      thresholds = grafana.thresholds.usage;
      gridPos = { h = 7; w = 8; x = 0; y = 20; };
      id = 31;
      targets = [
        (grafana.mkPromTarget {
          expr = ''(1 - node_filesystem_avail_bytes{instance=~"${builderInst}",mountpoint="/"} / node_filesystem_size_bytes{instance=~"${builderInst}",mountpoint="/"}) * 100'';
          legendFormat = "/ usage";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Disk Space (Root / Nix Store)";
      unit = "decbytes";
      fillOpacity = 20;
      gridPos = { h = 7; w = 8; x = 8; y = 20; };
      id = 32;
      targets = [
        (grafana.mkPromTarget {
          expr = ''node_filesystem_size_bytes{instance=~"${builderInst}",mountpoint="/"} - node_filesystem_avail_bytes{instance=~"${builderInst}",mountpoint="/"}'';
          legendFormat = "used";
        })
      ];
    })
    (grafana.mkStatPanel {
      title = "Nix Store Disk Used";
      unit = "decbytes"; decimals = 1;
      gridPos = { h = 7; w = 8; x = 16; y = 20; };
      id = 33;
      targets = [
        (grafana.mkPromTarget {
          expr = ''node_filesystem_size_bytes{instance=~"${builderInst}",mountpoint="/"} - node_filesystem_avail_bytes{instance=~"${builderInst}",mountpoint="/"}'';
          legendFormat = "used";
        })
      ];
    })

    # ═══ Host Resources (builder) ════════════════════════════════════
    (grafana.mkRow { title = "Host Resources (builder)"; y = 27; id = 40; })
    (panels.infra.cpuUsage    { instance = builderInst; gridPos = { h = 7; w = 6; x = 0;  y = 28; }; id = 41; })
    (panels.infra.memoryUsage { instance = builderInst; gridPos = { h = 7; w = 6; x = 6;  y = 28; }; id = 42; })
    (panels.infra.diskUsage   { instance = builderInst; mountpoint = "/"; gridPos = { h = 7; w = 6; x = 12; y = 28; }; id = 43; })
    (panels.infra.networkIO   { instance = builderInst; deviceMatch = ''device!~"lo|veth.*|br-.*|docker.*"''; gridPos = { h = 7; w = 6; x = 18; y = 28; }; id = 44; })
  ];
}
