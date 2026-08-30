{ config, lib, pkgs, stackId ? null, ... }:

# LXC container + KVM VM emitter for a single leaf stack.

let
  helpers = import ../../lib/tf/proxmox.nix { inherit config lib pkgs; };

  computeInStack = lib.filterAttrs
    (_: c: (c.enabled or true)
           && "${c.env}.${c.stack}" == stackId
           && lib.hasPrefix "proxmox." c.provider_instance)
    config.fleet.compute;

  containers = lib.filterAttrs (_: c: c.kind == "container") computeInStack;
  vms        = lib.filterAttrs (_: c: c.kind == "vm") computeInStack;

  emitContainers = lib.mapAttrs helpers.mkContainer containers;
  emitVms        = lib.mapAttrs helpers.mkVm vms;

in {
  config = lib.mkIf (stackId != null && computeInStack != {}) (
    lib.mkMerge [
      (lib.mkIf (containers != {}) {
        resource.proxmox_virtual_environment_container = emitContainers;
      })
      (lib.mkIf (vms != {}) {
        resource.proxmox_virtual_environment_vm = emitVms;
      })
    ]
  );
}
