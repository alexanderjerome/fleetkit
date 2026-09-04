{ config, lib, pkgs, modulesPath, ... }:

# PVE LXC platform — unprivileged LXC containers on a Proxmox host.
#
# Imports the upstream NixOS proxmox-lxc profile UNCONDITIONALLY because
# Nix can't gate imports on config. Non-LXC platforms (pve.qemu /
# xcpng.vm) cancel its effect with `proxmoxLXC.enable = lib.mkForce
# false` in their own platform modules.

let
  cfg = config.infra.platform.pve.lxc;
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  options.infra.platform.pve.lxc = {
    gpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The PVE host passes GPU nodes through to this container
        (fleet.compute.<name>.devices with /dev/dri/*, /dev/kfd or
        /dev/nvidia*). Enables the graphics userland and pins the video /
        render groups to the gids in `deviceGids`, which is what the
        passthrough entries must carry as `gid` so the nodes are usable
        inside the (unprivileged) container.
      '';
    };
    deviceGids = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      readOnly = true;
      default = { video = config.ids.gids.video; render = config.ids.gids.render; };
      defaultText = lib.literalExpression "{ video = config.ids.gids.video; render = config.ids.gids.render; }";
      description = "Group ids the guest uses for /dev/dri/card* (video) and /dev/dri/renderD* + /dev/kfd (render). The fleet side must pass the same numbers as `devices[].gid`; NixOS' ids are 26 and 303 (Debian's 44 / 104 in the community scripts).";
    };
  };

  config = lib.mkIf (config.infra.platform.type == "pve.lxc") {
    proxmoxLXC.manageHostName = true;

    # GPU passthrough: userland + fixed gids on both groups so a devN
    # entry with gid=26/303 maps to a real group in the guest. Service
    # users are added to these groups by their app modules.
    hardware.graphics.enable = lib.mkIf cfg.gpu.enable true;
    users.groups.video.gid = lib.mkIf cfg.gpu.enable config.ids.gids.video;
    users.groups.render.gid = lib.mkIf cfg.gpu.enable config.ids.gids.render;

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
