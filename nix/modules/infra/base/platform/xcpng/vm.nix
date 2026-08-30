{ config, lib, pkgs, ... }:

# XCP-ng VM platform — UEFI + systemd-boot, LTS kernel, Xen frontends.
#
# Distinct enough from the PVE-VM case to deserve its own module: GRUB
# doesn't apply (no /dev/vda; UEFI firmware-style is different), boot
# loader is systemd-boot, kernel needs the LTS pin (6.18 has a
# xen-blkfront regression on this XCP-ng stack), and the console
# fan-out includes hvc0.
#
# Bootstrap-image.nix (./bootstrap-image.nix) duplicates much of this
# because nixos-anywhere builds its closure outside the fleet eval —
# at runtime + post-Colmena the two paths converge here.

{
  config = lib.mkIf (config.infra.platform.type == "xcpng.vm") {
    # Cancel proxmox-lxc.nix (imported by ../pve/lxc.nix for the LXC
    # branch). On an XCP-ng VM there's no PVE at all.
    proxmoxLXC.enable = lib.mkForce false;

    # Xen guest agent only. qemuGuest expects /dev/virtio-ports/* (a
    # virtio-serial channel into a QEMU host) — that doesn't exist on
    # XCP-ng, the service crashloops on missing transport, and the
    # restart churn was implicated in one of the netcore boot-stall
    # reproductions. Pin off explicitly.
    services.xe-guest-utilities.enable = true;
    services.qemuGuest.enable = lib.mkForce false;

    # UEFI + systemd-boot. XCP-ng UEFI templates ship NVRAM that boots
    # from \EFI\BOOT\BOOTX64.EFI; systemd-boot installs there cleanly.
    # GRUB-on-MBR (the PVE VM path) doesn't apply.
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce true;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce true;

    # LTS kernel pin. The "current" channel kernel (6.18.x at the time
    # of writing) carries a xen-blkfront regression on this XCP-ng
    # version: disk + net traffic goes silent ~2 min after first boot,
    # hypervisor still reporting Running. Upstream NixOS 26.05 minimal
    # installer pins 6.12 and runs cleanly; match that until 6.18+
    # ships the fix. Drop the pin when validated.
    boot.kernelPackages = pkgs.linuxPackages_6_12;

    # Xen frontends (block + net) in the initrd so stage-1 sees
    # /dev/xvda. The PVE VM case has only virtio modules here; without
    # xen_blkfront the EFI stub finishes handing off and the kernel
    # hangs immediately on root-mount. ata_piix / uhci_hcd / sr_mod
    # match what nixos-generate-config picks on this VM shape (Generic
    # Linux UEFI + Xen HVM); harmless on hosts that don't need them but
    # closes "cdrom not detected at install time" edges.
    boot.initrd.availableKernelModules = [
      "ata_piix" "uhci_hcd" "sr_mod"
      "xen_blkfront" "xen_netfront"
    ];
    boot.initrd.kernelModules = [ "ext4" ];
    # Force-load at runtime too. Initrd loads them once but some
    # auto-probe paths drop them; without runtime-loaded xen_blkfront
    # an under-load disk hang is a real symptom observed during netcore
    # Colmena pushes.
    boot.kernelModules = [ "xen_blkfront" "xen_netfront" ];

    # Console fan-out:
    #   tty0       — VGA-ish framebuffer; XO's console viewer attaches here
    #   hvc0       — Xen virtual console; survives bridge / NIC issues
    #   ttyS0      — serial-port emulator; XOA console fallback
    # Last `console=` wins for init stdout — ttyS0 chosen for log
    # capture parity with the PVE VM path.
    #
    # net.ifnames=0 + biosdevname=0: same fix as the PVE VM path.
    # XCP-ng's Xen frontends come up as eth0..eth3 in the kernel, then
    # a per-distribution udev rule renames them to enX0..enX3
    # asynchronously. systemd-networkd configs that match Name=eth0
    # win some boots and lose others. Forcing legacy naming at the
    # kernel level removes the rename and the race.
    boot.kernelParams = [
      "console=tty0" "console=hvc0" "console=ttyS0,115200"
      "net.ifnames=0" "biosdevname=0"
    ];
    systemd.services."serial-getty@hvc0".enable = true;
    systemd.services."serial-getty@ttyS0".enable = true;

    # Default root mount for cloned production VMs (no disko in their
    # closure — they inherit a pre-formatted disk from the template
    # clone). mkDefault so the bootstrap-image's disko config — which
    # emits its own fileSystems entries pointing at
    # /dev/disk/by-partlabel/* — wins at install time. Future XCP-ng
    # hosts with a different disko layout override likewise.
    fileSystems."/" = lib.mkDefault {
      device = "/dev/xvda2";
      fsType = "ext4";
    };
    fileSystems."/boot" = lib.mkDefault {
      device = "/dev/xvda1";
      fsType = "vfat";
      options = [ "umask=0077" ];
    };

    # systemd-networkd is the supported config path; turn off the
    # default scripted networking so the two don't race.
    systemd.network.enable = true;
    networking.useDHCP = false;

    # network-online without this default-waits for EVERY matched
    # interface to be routable, hitting the 120 s timeout on multi-NIC
    # XCP-ng hosts. Any-one online is enough for downstream services;
    # cap at 30 s so network-online.target doesn't gate boot.
    systemd.network.wait-online.anyInterface = lib.mkForce true;
    systemd.network.wait-online.timeout = lib.mkForce 30;
  };
}
