{ config, lib, ... }:

# PVE QEMU/KVM platform — full VMs on a Proxmox host (virtio block + net,
# BIOS GRUB, /dev/vda root).

{
  config = lib.mkIf (config.infra.platform.type == "pve.qemu") {
    # Cancel proxmox-lxc.nix (imported by ../pve/lxc.nix for the LXC
    # branch). On a VM there's no LXC, but the upstream module's options
    # would still drive activation steps if left enabled.
    proxmoxLXC.enable = lib.mkForce false;

    services.qemuGuest.enable = true;

    # virtio_blk is required for Proxmox VMs — disks attach as
    # virtio-blk-pci (not virtio-scsi). Without it stage-1 hangs on
    # "waiting for /dev/vda1". Discovered the hard way while
    # recovering an unbootable netgate VM.
    boot.loader.grub.enable = true;
    boot.loader.grub.device = "/dev/vda";
    boot.initrd.availableKernelModules = [
      "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"
    ];
    boot.initrd.kernelModules = [ "ext4" ];

    # Serial console fan-out so any post-kernel boot failure is visible
    # via `socat - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0` from
    # the PVE host. Last `console=` wins for init stdout — ttyS0 chosen
    # for log capture parity.
    #
    # net.ifnames=0 + biosdevname=0 forces legacy eth0/eth1 naming.
    # Without these, udev marks virtio NICs as ens18/ens19 before
    # systemd-networkd's `[Link] Name=eth0` rule fires, leaving network
    # configs (which match Name=eth0) orphaned and the host
    # SSH-unreachable. Documented in the post-deploy recovery on
    # 2026-05-19.
    boot.kernelParams = [
      "console=tty0" "console=ttyS0,115200"
      "net.ifnames=0" "biosdevname=0"
    ];
    systemd.services."serial-getty@ttyS0".enable = true;

    fileSystems."/" = {
      device = "/dev/vda1";
      fsType = "ext4";
    };

    # VMs use systemd-networkd just like LXC but need it explicitly
    # enabled (no proxmox-lxc.nix to do it for us).
    systemd.network.enable = true;
    networking.useDHCP = false;
  };
}
