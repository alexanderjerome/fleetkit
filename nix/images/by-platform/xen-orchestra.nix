# NixOS bootstrap image for XCP-ng / XOA (XCP-ng install path).
#
# Disko-driven single-disk layout, UEFI + systemd-boot. Produces one
# raw output per build:
#
#   result/main.raw → /dev/xvda  (root, UEFI-bootable)
#     ├─ xvda1  ESP   512 MiB  vfat   → /boot
#     └─ xvda2  ext4  rest            → /  (includes /nix)
#

# **Firmware: UEFI HVM (systemd-boot).** Earlier iterations tried BIOS
# HVM + GRUB to match the default "Other install media" template
# firmware, but the kernel hung silently in early init on Xen HVM
# BIOS right after the decompressor's "Booting the kernel" line
# (v3/v4 — neither `nokaslr` nor `earlyprintk` produced any output
# past that point, suggesting a CPU-state-level problem in the BIOS
# boot path that isn't worth chasing). UEFI + systemd-boot is the
# canonical NixOS path; the matching `hvm_boot_firmware = "uefi"`
# lives in nix/lib/tf/xen-orchestra.nix mkXoVm.
#
# Single-disk choice: the multi-disk layout (v10 era) broke v11
# template cloning — when we attached two pre-existing VDIs via
# vm.attachDisk and then convertToTemplate'd, XCP-ng materialised
# both VBDs with device=None instead of device=xvda/xvdb, so cloned
# VMs ended up with 0 disks. Single-disk side-steps that path entirely
# and matches the working v10 baseline pattern.
#
# Disko semantics: this module ONLY runs at image build time. The
# resulting raws are uploaded as XCP-ng template disks. Live VMs
# clone the template; `nixos-rebuild switch` on a running VM never
# re-invokes disko, so a flake-side disko config change can't wipe
# data on existing hosts. Caveat: deliberately running the `disko`
# CLI against a live disk WILL wipe; we don't have a path that
# triggers that.
#
# Bootstrap surface (baked into the root disk):
#   - explicit systemd-networkd DHCP on the WAN NIC (works without
#     a cloud-config drive — NixOS XOA VMs deliberately don't get
#     one, see wantsCloudConfig in nix/lib/tf/xen-orchestra.nix)
#   - qemu-guest-agent + xe-guest-utilities (so XOA reports IPs back
#     to `fleet inventory generate`'s discovery patcher)
#   - openssh + sysadmin pubkey on root
#   - serial console (XOA console + ttyS0 getty)
#   - sops-nix age-key staging directory
#
# Build:
#   nix build .#nixos-xcpng-template
#   # result/main.raw — runbook converts to VHD via
#   # `qemu-img convert -f raw -O vpc` before
#   # `xo-cli disk.import type=vhd`.

{ pkgs, disko, nixpkgsLib
  # Operator SSH public key granted root access on the fresh VM so
  # Colmena's first push can reach it. null (the bare flake-package
  # default) bakes NO key — pass your fleet's key (e.g.
  # config.fleet.network.sysadmin_ssh_key) for a usable template.
, sshPubKey ? null
}:

let
  diskoConfig = { ... }: {
    imports = [ disko.nixosModules.disko ];

    disko.devices = {
      disk = {
        # ── Single root disk: GPT + ESP + ext4 (UEFI-bootable) ──
        # /nix lives inside the root filesystem (no separate VHD).
        # Operator resize: `xo-cli vdi.set size=...` → grow-storage
        # service at next boot extends xvda2 + resize2fs.
        main = {
          type = "disk";
          device = "/dev/vda";  # libvirt/qemu virtio convention; XCP-ng renames to xvda
          imageSize = "8G";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };
      };
    };
  };

  systemConfig = { pkgs, lib, modulesPath, ... }: {
    imports = [
      "${modulesPath}/profiles/qemu-guest.nix"
      diskoConfig
    ];

    # ── Boot: UEFI + systemd-boot ─────────────────────────────
    # canTouchEfiVariables = false because the build VM doesn't run
    # under real UEFI firmware (it's a qemu image-build context);
    # systemd-boot just installs its files to /boot and XOA's UEFI
    # firmware finds them at first boot of the cloned VM.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;

    boot.initrd.availableKernelModules = [
      # Xen PV (HVM accelerated) + QEMU virtio fallbacks.
      # xen-platform-pci is BUILT-IN to the kernel, not a module —
      # listing it here would make modprobe fail during shrink.
      "xen_blkfront" "xen_netfront"
      "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"
    ];
    boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
    systemd.services."serial-getty@ttyS0".enable = true;

    # ── Agents XOA needs to report IPs back ───────────────────
    services.qemuGuest.enable = true;
    services.xe-guest-utilities.enable = true;

    # ── Network: explicit DHCP on the WAN NIC via networkd ─────
    # No cloud-config drive on NixOS XOA VMs (see wantsCloudConfig),
    # so we bring up an interface ourselves at first boot.
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.networks."10-wan" = {
      matchConfig.Name = [ "eth*" "en*" ];
      networkConfig.DHCP = "ipv4";
      # SendHostname=true → DHCP request advertises the kernel
      # hostname so UDM's lease DB keys by name (not just MAC),
      # giving distinct VMs distinct leases instead of all racing
      # for the same first-free address.
      dhcpV4Config = {
        UseHostname = false;
        SendHostname = true;
        # ClientIdentifier=mac forces the DHCP client ID to the
        # interface MAC (not the systemd-default duid+iaid). UDM's
        # lease binding is then keyed on the same identity that
        # tofu pins via mac_address_eth0, so a recreated VM with
        # the same MAC gets the same lease deterministically.
        ClientIdentifier = "mac";
      };
    };

    # ── grow-storage on boot ───────────────────────────────────
    # First boot after a `xo-cli vdi.set size=...` operator resize:
    # extend xvda2 (the / partition; GPT layout) and the raw ext4
    # filesystem on xvdb (/nix; no partition table). Idempotent —
    # every subsequent boot is a no-op until the next resize.
    environment.systemPackages = [ pkgs.cloud-utils ];   # provides growpart
    systemd.services.grow-storage = {
      description = "Grow root partition + /nix to fill underlying VDIs";
      wantedBy = [ "local-fs.target" ];
      after = [ "local-fs-pre.target" ];
      before = [ "local-fs.target" ];
      unitConfig.DefaultDependencies = "no";
      path = with pkgs; [ cloud-utils parted e2fsprogs util-linux coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "120";
      };
      script = ''
        set -eu
        # Root: GPT partition 2 on xvda. growpart → resize2fs.
        if [ -b /dev/xvda2 ]; then
          growpart /dev/xvda 2 || true
          resize2fs /dev/xvda2 || true
        fi
      '';
    };

    # ── SSH + sysadmin ─────────────────────────────────────────
    systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];
    users.mutableUsers = false;
    # A bare build without sshPubKey produces a deliberately
    # credential-less image (console access only) — silence NixOS's
    # lockout assertion for that case.
    users.allowNoPasswordLogin = sshPubKey == null;
    users.users.root = {
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = nixpkgsLib.optional (sshPubKey != null) sshPubKey;
    };
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    system.stateVersion = "25.11";
  };

  evalSystem = nixpkgsLib.nixosSystem {
    system = "x86_64-linux";
    modules = [ systemConfig ];
  };

in
  # disko-images is a derivation that builds one raw image per disk
  # declared in disko.devices.disk.<name>. Result layout:
  #   $out/main.raw
  #   $out/nix.raw
  # Convert each to VHD via `qemu-img convert -f raw -O vpc` before
  # `xo-cli disk.import type=vhd` (see ADR-022 §4 runbook).
  evalSystem.config.system.build.diskoImages
