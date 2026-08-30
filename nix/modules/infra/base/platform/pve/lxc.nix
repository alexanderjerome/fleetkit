{ config, lib, modulesPath, ... }:

# PVE LXC platform — unprivileged LXC containers on a Proxmox host.
#
# Imports the upstream NixOS proxmox-lxc profile UNCONDITIONALLY because
# Nix can't gate imports on config. Non-LXC platforms (pve.qemu /
# xcpng.vm) cancel its effect with `proxmoxLXC.enable = lib.mkForce
# false` in their own platform modules.

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  config = lib.mkIf (config.infra.platform.type == "pve.lxc") {
    proxmoxLXC.manageHostName = true;

    # Mounts the kernel rejects inside an unprivileged container, plus
    # systemd-sysctl which can't read /proc/sys writes that container
    # doesn't own. Suppress at the unit level so the boot path stays
    # clean (failed units mask other failures).
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
      "systemd-sysctl.service"
    ];
  };
}
