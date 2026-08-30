# Unified NixOS bootstrap image for Proxmox.
#
# Builds either an LXC template (.tar.xz) or VM image (.vma.zst) based on
# the `type` argument. Minimal config: boot, DHCP on eth0, accept SSH.
# Everything else (users, services, secrets) comes from core.nix via Colmena.
#
# Build:
#   LXC:  nix-build nix/images/by-platform/proxmox.nix
#   VM:   nix-build nix/images/by-platform/proxmox.nix --arg type '"vm"'
#
# Results:
#   LXC:  ./result/tarball/nixos-lxc-image-*.tar.xz
#   VM:   ./result/*.vma.zst

{ pkgs ? import <nixpkgs> {}
, type ? "lxc"
  # Operator SSH public key granted root access on the fresh image so
  # Colmena's first push can reach it — fleets pass
  # config.fleet.network.sysadmin_ssh_key.
, sshPubKey ? throw "images/by-platform/proxmox.nix: pass sshPubKey (e.g. config.fleet.network.sysadmin_ssh_key)"
}:

let
  # ── Shared config (both LXC and VM) ──────────────────────────
  sharedConfig = { modulesPath, pkgs, ... }: {
    # NOTE: no baked eth0 network unit here (INFRA-86). The LXC and VM
    # paths get their first-boot address by different mechanisms:
    #   * LXC — PVE's NixOS setup plugin (PVE 9, ostype=nixos) writes a
    #           static /etc/systemd/network/eth0.network from the
    #           container's net0 ip=/gw= at create time, and the
    #           proxmox-lxc module's manageNetwork=false enables networkd
    #           to consume it. A baked `10-eth0.network` would sort
    #           before PVE's `eth0.network` and shadow it (that DHCP unit
    #           was exactly why fresh CTs came up on a DHCP lease instead
    #           of their declared internal_ip).
    #   * VM  — cloud-init injects ipconfig0 at boot (see vmConfig), so it
    #           keeps its own DHCP-on-first-boot fallback unit below.

    # SOPS key directory — Colmena uploads the age key here before activation.
    systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];

    # Root: bash shell + SSH key only.
    users.mutableUsers = false;
    users.users.root = {
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [ sshPubKey ];
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

  # ── LXC-specific config ─────────────────────────────────────
  lxcConfig = { modulesPath, ... }: {
    imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

    proxmoxLXC = {
      enable = true;
      manageNetwork = false;
      manageHostName = true;
      privileged = false;
    };

    # Suppress systemd units that fail in unprivileged containers.
    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
      "systemd-sysctl.service"
    ];
  };

  # ── VM-specific config ──────────────────────────────────────
  vmConfig = { modulesPath, lib, ... }: {
    imports = [ (modulesPath + "/virtualisation/proxmox-image.nix") ];

    # eth0 DHCP fallback — gives a routable address on first boot if
    # cloud-init's ipconfig0 hasn't landed yet, so Colmena can reach a
    # fresh VM. (LXCs deliberately omit this — see sharedConfig note.)
    systemd.network.networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config = { UseDNS = true; UseHostname = false; };
    };

    proxmox = {
      qemuConf = {
        cores = 2;
        memory = 2048;
        agent = true;
        # Boot order baked in at template creation. Without this
        # `boot:` lands EMPTY in the qm config and every clone of
        # this template fails to boot (SeaBIOS reports "no
        # bootable device"). Discovered during netgate recovery
        # 2026-05-18 — the broken state propagated from a previous
        # template build that had this same gap.
        boot = "order=virtio0";
      };
      # Cloud-init lets Proxmox inject ipconfig0/ipconfig1 and hostname
      # at boot — no DHCP racing, correct static IPs from day one.
      cloudInit.enable = true;
    };

    # QEMU guest agent — required for PVE API to read VM IPs (hosts.json)
    services.qemuGuest.enable = true;

    # Override GRUB device — proxmox-image.nix uses /dev/vda
    boot.loader.grub.device = lib.mkForce "/dev/vda";

    # Initrd modules for Proxmox virtio disks. Without virtio_blk the
    # kernel never sees /dev/vda and stage 1 hangs at "waiting for
    # /dev/vda1 to appear" — discovered during a gateway-VM recovery.
    # The same fix is in
    # nix/modules/infra/base/platform/pve/qemu.nix but that module only applies
    # AFTER a successful colmena deploy. Baking
    # it into the template means every fresh VM boots first time —
    # no more hand-built `initrd-virtio_blk-fixed` workarounds.
    boot.initrd.availableKernelModules = [
      "virtio_pci" "virtio_blk" "virtio_scsi" "ahci" "sd_mod"
    ];
    boot.initrd.kernelModules = [ "ext4" ];

    # Serial console so a future boot failure isn't a black box. PVE
    # already wires `serial0: socket` to every VM by default — we just
    # need the guest to write to it. Order matters: tty0 listed first
    # so /dev/console resolves to ttyS0 (last entry wins for init's
    # default stdout target).
    boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
    systemd.services."serial-getty@ttyS0".enable = true;
  };

  image = pkgs.nixos ({ ... }: {
    imports = [ sharedConfig ] ++ (if type == "lxc" then [ lxcConfig ] else [ vmConfig ]);
  });

in
  if type == "lxc"
  then image.image                         # .tar.xz for LXC
  else image.config.system.build.VMA or    # .vma.zst for VM
       image.config.system.build.diskoImages or
       image  # fallback — caller inspects result
