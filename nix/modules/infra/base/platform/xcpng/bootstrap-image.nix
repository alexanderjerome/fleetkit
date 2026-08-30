# Target NixOS system installed onto fresh XCP-ng VMs via
# `nixos-anywhere --flake .#xo-bootstrap root@<installer-ip>`.
# Replaces the old nix/images/xen-orchestra-bootstrap-system.nix
# (XCP-ng install path).
#
# What this is: the configuration.nix that lands on a VM's disk after
# disko formats it, consumed by disko's *target-formatter* mode (run
# live against actual XCP-ng disks) instead of its *image-builder* mode
# (the diskoImages derivation that bakes build-time device paths in).
#
# After nixos-anywhere completes, the VM reboots into the installed
# system from disk and the installer ISO is no longer needed. Operator
# then powers it off, converts to template (e.g. nixos-fleet-bootstrap-
# v10), points xo-template-nixos at it, and Terraform clones it for
# every future XOA VM.
#
# Wired as `flake.nixosConfigurations.xo-bootstrap` so nixos-anywhere
# can pick it up with `--flake .#xo-bootstrap`.
#
# Imports ../../core (the slim NixOS base) + ./vm.nix (XCP-ng VM
# platform settings) so the installed system inherits the exact same
# users, kernel pin, console fan-out, and Xen frontend config that a
# steady-state fleet host gets. Bootstrap-specific extras (root SSH key
# for nixos-anywhere, disko layout) layer on top.

{ disko, nixpkgsLib
  # Bootstrap-window credential: nixos-anywhere uses root SSH to land
  # the closure on a fresh installer. Once Colmena's first push runs,
  # core.nix's `users.users.root.openssh.authorizedKeys.keys` defaults
  # back to empty and root SSH is closed. Pass your fleet's operator
  # key (e.g. config.fleet.network.sysadmin_ssh_key); null bakes NO
  # key and the resulting system is unreachable over SSH.
, sshPubKey ? null
}:

nixpkgsLib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    disko.nixosModules.disko

    # ── Disko: single-disk layout ──────────────────────────────
    # v8/v9 of this template tried a multi-disk layout (xvda root +
    # xvdb /nix via by-label). On XCP-ng + NixOS 26.05's kernel that
    # combo had a reproducible "boots, runs ~2 min, then silent"
    # failure — the xvdb-backed /nix mount goes unresponsive and any
    # process needing the store hangs. Collapsing to a single disk
    # (xvda holds ESP + / which contains /nix) removes the failure
    # surface entirely. Disk growth is operator-driven via
    # `sk xoa resize-disk` (per `mkXoLifecycle` ignore_changes on
    # disk size).
    ({ ... }: {
      disko.devices = {
        disk = {
          main = {
            type = "disk";
            device = "/dev/xvda";
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
    })

    # ── Inherit fleet base + XCP-ng VM platform ────────────────
    # core/default.nix gives us users, ssh, locale, nix gc, single
    # eth0 DHCP. ../platform (transitively imported by core) gives us
    # the xcpng.vm gated block: UEFI + systemd-boot, LTS kernel, Xen
    # frontends in initrd, console fan-out. We just have to set the
    # platform type.
    ../../core

    # ── Bootstrap-specific overlay ─────────────────────────────
    ({ pkgs, lib, ... }: {
      infra.platform.type = "xcpng.vm";

      networking.hostName = "xo-bootstrap";

      # core already grants root SSH with the sysadmin key + sets
      # PermitRootLogin = prohibit-password, so nixos-anywhere works
      # against this template without further overlays. Left here as a
      # safety pin in case core's stance ever closes root SSH (the
      # bootstrap window still needs it open).
      users.users.root.openssh.authorizedKeys.keys =
        lib.optional (sshPubKey != null) sshPubKey;
      services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
    })
  ];
}
