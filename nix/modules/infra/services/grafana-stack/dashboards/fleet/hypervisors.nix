# Hypervisors — Proxmox VE cluster overview + per-node + per-container resources.
#
# Sourced from the OTLP proxmox exporter (job=proxmox-ve, INFRA-47/ADR-038):
# the PVE datacenter metric server pushes node/guest/storage stats to the
# Alloy gateway on the otel CT. Metrics are `proxmox_*` with labels:
#   proxmox_node_*    { node }                       — 7 cluster nodes
#   proxmox_vm_*      { node, name, vmid, type }     — guests (lxc/qemu)
#   proxmox_storage_* { node, storage }              — datastores
#
# The legacy prometheus-pve-exporter (pve_*, job=pve :9221) was dead (broken
# API token, up but 0 metrics) and has been removed — INFRA-128.
#
{ grafana, panels }:
grafana.mkDashboard {
  title = "Hypervisors";
  uid = "hypervisors";
  tags = [ "proxmox" "pve" "hypervisor" "infrastructure" ];
  refresh = "30s";
  timeFrom = "now-6h";
  panels = [

    # ── Cluster Overview ─────────────────────────────────────────
    (grafana.mkRow { title = "Proxmox VE — Cluster Overview"; y = 0; id = 1; })
    (grafana.mkStatPanel {
      title = "Running Guests";
      graphMode = "none";
      gridPos = { h = 4; w = 6; x = 0; y = 1; };
      id = 2;
      targets = [ (grafana.mkPromTarget { expr = "count(proxmox_vm_uptime_seconds > 0)"; legendFormat = "running"; }) ];
    })
    (grafana.mkStatPanel {
      title = "Cluster Nodes Online";
      graphMode = "none";
      gridPos = { h = 4; w = 6; x = 6; y = 1; };
      id = 3;
      targets = [ (grafana.mkPromTarget { expr = "count(proxmox_node_uptime_seconds > 0)"; legendFormat = "nodes"; }) ];
    })
    (grafana.mkGaugePanel {
      title = "Cluster CPU Usage";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green";  value = null; }
          { color = "yellow"; value = 0.7; }
          { color = "red";    value = 0.9; }
        ];
      };
      gridPos = { h = 4; w = 6; x = 12; y = 1; };
      id = 4;
      # proxmox_vm/node cpu_percent is a 0–1 fraction (PVE API semantics).
      targets = [ (grafana.mkPromTarget { expr = "avg(proxmox_node_cpustat_cpu_percent)"; legendFormat = "CPU"; }) ];
    })
    (grafana.mkGaugePanel {
      title = "Cluster Memory Usage";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = {
        mode = "absolute";
        steps = [
          { color = "green";  value = null; }
          { color = "yellow"; value = 0.7; }
          { color = "red";    value = 0.9; }
        ];
      };
      gridPos = { h = 4; w = 6; x = 18; y = 1; };
      id = 5;
      targets = [
        (grafana.mkPromTarget {
          expr = "sum(proxmox_node_memory_memused_bytes) / sum(proxmox_node_memory_memtotal_bytes)";
          legendFormat = "Memory";
        })
      ];
    })

    # ── Per-Node Resources ───────────────────────────────────────
    (grafana.mkRow { title = "Proxmox VE — Per-Node Resources"; y = 5; id = 10; })
    (grafana.mkTimeseriesPanel {
      title = "CPU Usage per Node";
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 10;
      gridPos = { h = 8; w = 8; x = 0; y = 6; };
      id = 11;
      targets = [ (grafana.mkPromTarget { expr = "proxmox_node_cpustat_cpu_percent"; legendFormat = "{{node}}"; }) ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Memory Usage per Node";
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 10;
      gridPos = { h = 8; w = 8; x = 8; y = 6; };
      id = 12;
      targets = [
        (grafana.mkPromTarget {
          expr = "proxmox_node_memory_memused_bytes / proxmox_node_memory_memtotal_bytes";
          legendFormat = "{{node}}";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Node Network I/O";
      unit = "Bps";
      fillOpacity = 10;
      gridPos = { h = 8; w = 8; x = 16; y = 6; };
      id = 13;
      targets = [
        (grafana.mkPromTarget { expr = "rate(proxmox_node_network_receive_bytes_total[5m])"; legendFormat = "{{node}} rx"; })
        (grafana.mkPromTarget { expr = "rate(proxmox_node_network_transmit_bytes_total[5m])"; legendFormat = "{{node}} tx"; refId = "B"; })
      ];
    })

    # ── Storage (thinpool / datastore fill) ──────────────────────
    # Surfaces datastore usage per node — the signal that goes red before a
    # thinpool-full incident wedges guests read-only (see INFRA-108/126).
    (grafana.mkRow { title = "Proxmox VE — Storage"; y = 14; id = 15; })
    (grafana.mkTimeseriesPanel {
      title = "Datastore Usage %";
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 10;
      thresholds = grafana.thresholds.usage;
      gridPos = { h = 8; w = 12; x = 0; y = 15; };
      id = 16;
      targets = [
        (grafana.mkPromTarget {
          expr = "proxmox_storage_used_bytes / proxmox_storage_total_bytes";
          legendFormat = "{{node}} / {{storage}}";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Datastore Free Space";
      unit = "decbytes";
      fillOpacity = 10;
      gridPos = { h = 8; w = 12; x = 12; y = 15; };
      id = 17;
      targets = [
        (grafana.mkPromTarget {
          expr = "proxmox_storage_avail_bytes";
          legendFormat = "{{node}} / {{storage}}";
        })
      ];
    })

    # ── Container Status ─────────────────────────────────────────
    (grafana.mkRow { title = "Proxmox VE — Guest Status"; y = 23; id = 20; })
    (grafana.mkTablePanel {
      title = "Guest Status";
      gridPos = { h = 14; w = 24; x = 0; y = 24; };
      id = 21;
      sortBy = [{ displayName = "Name"; desc = false; }];
      targets = [
        (grafana.mkPromTarget { expr = "proxmox_vm_cpu_percent"; format = "table"; instant = true; })
        (grafana.mkPromTarget { expr = "proxmox_vm_mem_bytes / proxmox_vm_maxmem_bytes"; format = "table"; instant = true; refId = "B"; })
        (grafana.mkPromTarget { expr = "proxmox_vm_uptime_seconds"; format = "table"; instant = true; refId = "C"; })
      ];
      transformations = [
        { id = "merge"; options = {}; }
        {
          id = "organize";
          options = {
            excludeByName = { Time = true; "__name__" = true; job = true; };
            renameByName = {
              name = "Name";
              node = "Node";
              vmid = "VMID";
              type = "Type";
              "Value #A" = "CPU (cores)";
              "Value #B" = "Memory %";
              "Value #C" = "Uptime (s)";
            };
          };
        }
      ];
    })

    # ── Per-Container Resources ──────────────────────────────────
    (grafana.mkRow { title = "Proxmox VE — Per-Container Resources"; y = 38; id = 30; })
    (grafana.mkTimeseriesPanel {
      title = "CPU Usage per Container (cores)";
      unit = "percentunit"; min = 0;
      fillOpacity = 10;
      gridPos = { h = 8; w = 12; x = 0; y = 39; };
      id = 31;
      targets = [ (grafana.mkPromTarget { expr = "proxmox_vm_cpu_percent"; legendFormat = "{{name}}"; }) ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Memory Usage per Container (GiB)";
      unit = "gbytes";
      fillOpacity = 10;
      gridPos = { h = 8; w = 12; x = 12; y = 39; };
      id = 32;
      targets = [
        (grafana.mkPromTarget {
          expr = "proxmox_vm_mem_bytes / 1073741824";
          legendFormat = "{{name}}";
        })
      ];
    })

    # ── Per-Container I/O ────────────────────────────────────────
    (grafana.mkRow { title = "Proxmox VE — Per-Container I/O"; y = 47; id = 40; })
    (grafana.mkTimeseriesPanel {
      title = "Disk I/O per Container";
      unit = "Bps";
      fillOpacity = 10;
      gridPos = { h = 8; w = 12; x = 0; y = 48; };
      id = 41;
      targets = [
        (grafana.mkPromTarget { expr = "rate(proxmox_vm_diskread_bytes_total[5m])"; legendFormat = "{{name}} read"; })
        (grafana.mkPromTarget { expr = "rate(proxmox_vm_diskwrite_bytes_total[5m])"; legendFormat = "{{name}} write"; refId = "B"; })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Network I/O per Container";
      unit = "Bps";
      fillOpacity = 10;
      gridPos = { h = 8; w = 12; x = 12; y = 48; };
      id = 42;
      targets = [
        (grafana.mkPromTarget { expr = "rate(proxmox_vm_netin_bytes_total[5m])"; legendFormat = "{{name}} rx"; })
        (grafana.mkPromTarget { expr = "rate(proxmox_vm_netout_bytes_total[5m])"; legendFormat = "{{name}} tx"; refId = "B"; })
      ];
    })
  ];
}
