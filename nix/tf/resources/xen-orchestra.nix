{ config, lib, stackId ? null, ... }:

# Xen-Orchestra resources — inert tonight.
# Emits data.xenorchestra_* blocks (not resource.*) for XCP-ng
# primitives that already exist on the bare metal and should be
# imported as read-only data sources.

let
  helpers = import ../../lib/tf/xen-orchestra.nix { inherit config lib; };

  resourcesInStack = lib.filterAttrs
    (_: r: "${r.env}.${r.stack}" == stackId
           && lib.hasPrefix "xo-" r.kind)
    config.fleet.resources;

  byKind = lib.groupBy (r: r.kind)
    (lib.mapAttrsToList (name: meta: meta // { _name = name; }) resourcesInStack);

  emitKind = entries: handler:
    lib.listToAttrs (map (e: { name = e._name; value = handler e._name e; }) entries);

  poolEntries = byKind."xo-pool" or [];
  netEntries  = byKind."xo-network" or [];
  srEntries   = byKind."xo-sr" or [];
  tmplEntries = byKind."xo-template" or [];
  isoEntries  = byKind."xo-iso" or [];

in {
  config = lib.mkIf (stackId != null && resourcesInStack != {}) (lib.mkMerge [
    (lib.mkIf (poolEntries != []) { data.xenorchestra_pool     = emitKind poolEntries helpers.mkXoPool; })
    (lib.mkIf (netEntries != [])  { data.xenorchestra_network  = emitKind netEntries  helpers.mkXoNetwork; })
    (lib.mkIf (srEntries != [])   { data.xenorchestra_sr       = emitKind srEntries   helpers.mkXoSr; })
    (lib.mkIf (tmplEntries != []) { data.xenorchestra_template = emitKind tmplEntries helpers.mkXoTemplate; })
    (lib.mkIf (isoEntries != [])  { data.xenorchestra_vdi      = emitKind isoEntries  helpers.mkXoIso; })
  ]);
}
