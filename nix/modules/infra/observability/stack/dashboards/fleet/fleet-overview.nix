# Fleet Overview dashboard — auto-generated from hosts.json.
#
# Produces:
#   Row 1: Container status grid (pve_up per VMID)
#   Row 2: Host resource summary table (node_exporter)
#   Row 3: Fleet inventory table (static markdown)
#
{ lib, grafana, runtime }:
let
  hosts = lib.sort (a: b: a.vmid < b.vmid) (
    lib.mapAttrsToList (name: h: {
      inherit name;
      vmid = h.vmid;
      ip = h.internal_ip or h.ip or "";
      tags = h.tags or [];
    }) runtime
  );

  hostCount = builtins.length hosts;
  cols = 6;

  # ── Container Status Grid ──────────────────────────────────────
  # Sourced from the OTLP proxmox exporter (job=proxmox-ve). A running guest
  # reports proxmox_vm_uptime_seconds keyed by `vmid`; `> bool 0` yields 1 so
  # the binary-threshold stat goes green. Stopped/retired guests are absent
  # from the exporter and render as "No Data" (grey). The old pve_* exporter
  # (job=pve, :9221) is dead — INFRA-128.
  containerPanels = grafana.mkStatusGrid {
    y = 2;
    idBase = 100;
    inherit cols;
    hosts = map (h: {
      name = h.name;
      label = "${h.name} (${h.ip})";
      expr = ''proxmox_vm_uptime_seconds{vmid="${toString h.vmid}"} > bool 0'';
    }) hosts;
  };

  containerRowEnd = 2 + ((hostCount + cols - 1) / cols) * 3;

  # ── Host Resource Table ────────────────────────────────────────
  resourceTableY = containerRowEnd + 1;

  resourceTable = grafana.mkTablePanel {
    title = "Host Resources";
    gridPos = { h = 10; w = 24; x = 0; y = resourceTableY; };
    id = 50;
    sortBy = [{ displayName = "Instance"; desc = false; }];
    targets = [
      (grafana.mkPromTarget {
        expr = ''up{job="integrations/node_exporter"}'';
        format = "table"; instant = true;
      })
      (grafana.mkPromTarget {
        expr = ''100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'';
        format = "table"; instant = true; refId = "B";
      })
      (grafana.mkPromTarget {
        expr = ''100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'';
        format = "table"; instant = true; refId = "C";
      })
      (grafana.mkPromTarget {
        expr = ''100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})'';
        format = "table"; instant = true; refId = "D";
      })
    ];
    transformations = [
      { id = "merge"; options = {}; }
      {
        id = "organize";
        options = {
          excludeByName = { Time = true; "__name__" = true; job = true; };
          renameByName = {
            "Value #A" = "Up";
            "Value #B" = "CPU %";
            "Value #C" = "Memory %";
            "Value #D" = "Disk %";
            instance = "Instance";
          };
        };
      }
    ];
  };

  # ── Fleet Inventory (static markdown) ──────────────────────────
  inventoryY = resourceTableY + 11;

  inventoryMarkdown = lib.concatStringsSep "\n" ([
    "| VMID | Host | IP | Tags |"
    "|------|------|----|------|"
  ] ++ map (h:
    "| ${toString h.vmid} | **${h.name}** | ${h.ip} | ${lib.concatStringsSep ", " h.tags} |"
  ) hosts);

in
grafana.mkDashboard {
  title = "Fleet Overview";
  uid = "fleet-overview";
  tags = [ "fleet" "overview" "auto-generated" ];
  description = "Auto-generated from hosts.json — container status, resource usage, fleet inventory.";
  panels = [
    (grafana.mkRow { title = "Container Status (via proxmox-ve exporter)"; y = 0; id = 1; })
  ] ++ containerPanels ++ [
    (grafana.mkRow { title = "Host Resources (node_exporter)"; y = containerRowEnd; id = 2; })
    resourceTable
    (grafana.mkRow { title = "Fleet Inventory"; y = inventoryY - 1; id = 3; })
    (grafana.mkTextPanel {
      title = "Fleet Inventory";
      content = inventoryMarkdown;
      gridPos = { h = 12; w = 24; x = 0; y = inventoryY; };
      id = 60;
    })
  ];
}
