# NixOS minimal installer ISO for the XCP-ng / XOA bootstrap
# (XCP-ng install path, not image-build path).
#
# Why this exists: building the target system as a pre-formatted
# image (the qcow2/disko-images route in xen-orchestra.nix) hit a
# wall on Xen HVM — disko's whole-disk filesystem content type
# bakes the build-time virtio device path (/dev/vdb) into the
# generated fileSystems entry, which doesn't exist on XCP-ng
# (/dev/xvdb there). Various attempts to fix it (v3 BIOS+GRUB,
# v5 UEFI metadata flip, v6 Generic Linux UEFI base, v7 by-label
# override) hit successive issues. The canonical NixOS pattern
# for this situation is `nixos-anywhere`: boot ANY recoverable
# Linux on the target, push our flake's nixosConfiguration over
# SSH, and let disko's *target-formatter* mode (not its
# image-builder mode) run against the actual XCP-ng-side disks.
# That sidesteps the device-name mismatch entirely because the
# disks are real and visible from the live installer.
#
# What this ISO contains beyond the stock nixpkgs minimal
# installer: sshd up on first boot, root authorized_keys
# pre-loaded with the sysadmin pubkey, networkd DHCP on
# eth*/en*, xe-guest-utilities so XOA reports the DHCP'd IP back
# via the REST API (which `sk inventory generate` already
# patches into hosts.json).
#
# Lifecycle: build, upload to the NFS ISO Library SR ONCE, then
# boot the installer VM, `nixos-anywhere --flake .#xo-bootstrap
# root@<ip>`, watch it install + reboot, convert to template.
# After the template exists, this ISO is rarely needed again.
#
# Build:
#   nix build .#nixos-xcpng-installer-iso
#   # result/iso/nixos-*.iso — upload via
#   # `xo-cli disk.import url=... type=iso sr=$NFS_ISO_LIBRARY`

{ pkgs, nixpkgsLib
  # Operator SSH public key granted root access on the live installer
  # so nixos-anywhere can drive it. null (the bare flake-package
  # default) bakes NO key — pass your fleet's key (e.g.
  # config.fleet.network.sysadmin_ssh_key) for a usable installer.
, sshPubKey ? null
}:

let
  installer = nixpkgsLib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ({ modulesPath, lib, pkgs, ... }: {
        imports = [
          "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
          "${modulesPath}/installer/cd-dvd/channel.nix"
        ];

        # ── SSH wide open on the installer (it's short-lived) ────
        # The installer ISO sits on the NFS ISO Library and only
        # runs during the one-shot install. Root login with our
        # pubkey is fine for that window.
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "prohibit-password";
          settings.PasswordAuthentication = false;
        };
        users.users.root.openssh.authorizedKeys.keys =
          nixpkgsLib.optional (sshPubKey != null) sshPubKey;

        # ── Xen-side IP visibility ────────────────────────────────
        # So XOA's REST API populates `addresses` for the installer
        # VM and `sk inventory generate` can hand us its DHCP'd
        # WAN IP. Without this, we'd be stuck reading the IP off
        # the XOA console manually.
        services.xe-guest-utilities.enable = true;

        # ── Network: DHCP on the WAN NIC ──────────────────────────
        # XOA's xenbr3 (WAN) has a DHCP server reachable to VMs.
        # Match eth* and en* — the live installer kernel may pick
        # either naming.
        networking.useDHCP = false;
        networking.useNetworkd = true;
        systemd.network.networks."10-wan" = {
          matchConfig.Name = [ "eth*" "en*" ];
          networkConfig.DHCP = "ipv4";
        };

        # ── Console + Xen PV driver visibility ───────────────────
        # Fan-out tty0 / hvc0 (Xen virtual console) / ttyS0 so any
        # one being viewable from the XOA UI surfaces boot progress.
        # The previous installer revision had only tty0+ttyS0 and
        # hvc0 was sometimes the only working channel.
        boot.kernelParams = [
          "console=tty0" "console=hvc0" "console=ttyS0,115200"
        ];
        boot.initrd.availableKernelModules = [
          "xen_blkfront" "xen_netfront"
          "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"
        ];
        systemd.services."serial-getty@hvc0".enable = true;
        systemd.services."serial-getty@ttyS0".enable = true;

        # ── LTS kernel pin ───────────────────────────────────────
        # The 26.05 nixpkgs default is the latest kernel (6.18.x at
        # time of writing), which carries a xen-blkfront regression
        # on this XCP-ng pool: disk + net traffic goes silent ~2 min
        # after first boot. Stock upstream 26.05 minimal installer
        # pins 6.12 and runs cleanly. We pin to match.
        # nix/modules/infra/base/platform/xcpng/vm.nix carries the same pin for
        # post-install systems; both layers stay aligned so the
        # installer doesn't fall over before nixos-anywhere finishes.
        boot.kernelPackages = pkgs.linuxPackages_6_12;

        # ── Pre-install convenience ──────────────────────────────
        # Bake nixos-anywhere into the installer in case operator
        # wants to flip the script and run it FROM the installer
        # against another target later.
        environment.systemPackages = with pkgs; [
          git curl jq
        ];

        # stateVersion must be set even on the installer to silence
        # the eval warning.
        system.stateVersion = "25.11";
      })
    ];
  };
in
  installer.config.system.build.isoImage
