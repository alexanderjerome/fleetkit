{ config, lib, pkgs, stackId ? null, ... }:

# Emits proxmox non-OS resources (bridges, pools, ACLs, realms, DNS,
# downloads, files) that belong to the current stack (stackId).
#
# Module called once per leaf stack — only entries whose
# "${env}.${stack}" matches the active stackId get emitted.
#
# pkgs flows through to mkFile so it can resolve nix-built sources like
# the prepared Debian cloud image (ADR-018).

let
  helpers = import ../../lib/tf/proxmox.nix { inherit config lib pkgs; };

  resourcesInStack = lib.filterAttrs
    (_: r: "${r.env}.${r.stack}" == stackId)
    config.fleet.resources;

  byKind = lib.groupBy (r: r.kind)
    (lib.mapAttrsToList
      (name: meta: meta // { _name = name; })
      resourcesInStack);

  # Per-kind emit: { "<name>" = <tf-block>; ... }
  emitKind = entries: handler:
    lib.listToAttrs (map (e: { name = e._name; value = handler e._name e; }) entries);

  bridgeEntries          = byKind.bridge or [];
  poolEntries            = byKind.pool or [];
  groupEntries           = byKind.group or [];
  aclEntries             = byKind.acl or [];
  dnsEntries             = byKind.dns or [];
  downloadEntries        = byKind.download or [];
  fileEntries            = byKind.file or [];
  clusterOptionsEntries  = byKind."cluster-options" or [];
  metricsServerEntries   = byKind."metrics-server" or [];

in {
  config = lib.mkIf (stackId != null && resourcesInStack != {}) (lib.mkMerge [
    (lib.mkIf (bridgeEntries != []) {
      resource.proxmox_network_linux_bridge = emitKind bridgeEntries helpers.mkBridge;
    })
    (lib.mkIf (poolEntries != []) {
      resource.proxmox_virtual_environment_pool = emitKind poolEntries helpers.mkPool;
    })
    (lib.mkIf (groupEntries != []) {
      resource.proxmox_virtual_environment_group = emitKind groupEntries helpers.mkGroup;
    })
    (lib.mkIf (aclEntries != []) {
      resource.proxmox_acl = emitKind aclEntries helpers.mkAcl;
    })
    (lib.mkIf (dnsEntries != []) {
      resource.proxmox_virtual_environment_dns = emitKind dnsEntries helpers.mkDns;
    })
    (lib.mkIf (downloadEntries != []) {
      resource.proxmox_download_file = emitKind downloadEntries helpers.mkDownload;
    })
    (lib.mkIf (fileEntries != []) {
      resource.proxmox_virtual_environment_file = emitKind fileEntries helpers.mkFile;
    })
    (lib.mkIf (clusterOptionsEntries != []) {
      # bpg/proxmox renamed proxmox_virtual_environment_cluster_options →
      # proxmox_cluster_options; the old name is removed in v1.0. Existing
      # state was migrated via `tofu state mv` (see commit message).
      resource.proxmox_cluster_options = emitKind clusterOptionsEntries helpers.mkClusterOptions;
    })
    (lib.mkIf (metricsServerEntries != []) {
      # bpg renamed proxmox_virtual_environment_metrics_server →
      # proxmox_metrics_server (old name removed in v1.0), same as
      # cluster-options above. Use the new name from the start.
      resource.proxmox_metrics_server =
        emitKind metricsServerEntries helpers.mkMetricsServer;
    })
  ]);
}
