# Minimal NixOS LXC bootstrap image for Proxmox.
#
# Purpose: boot, get a DHCP address on eth0, accept SSH → Colmena takes over.
# Everything else (users, locale, packages, secrets) comes from core.nix
# via Colmena deploy. Keep this file as small as possible.
#
# Build on PVE host:  nix-build bootstrap.nix
# Result:             ./result/tarball/nixos-lxc-image-*.tar.xz

{ pkgs ? import <nixpkgs> {}
  # Operator SSH public key granted root access so Colmena's first push
  # can reach the fresh container:
  #   nix-build bootstrap.nix --argstr sshPubKey "ssh-ed25519 AAAA..."
, sshPubKey ? throw "images/bootstrap.nix: pass sshPubKey (the operator SSH public key baked into the image)"
}:

(pkgs.nixos ({ modulesPath, pkgs, ... }: {
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    enable         = true;
    manageNetwork  = false;
    manageHostName = true;
    privileged     = false;
  };

  # eth0 DHCP — get a routable address on first boot so Colmena can reach us.
  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    networkConfig.DHCP = "ipv4";
    dhcpV4Config = { UseDNS = true; UseHostname = false; };
  };

  # LXC systemd fixes — suppress units that fail in unprivileged containers.
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
    "systemd-sysctl.service"
  ];

  # SOPS key directory — Colmena uploads the age key here before activation.
  systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];

  # Root: bash shell (so pct enter gets NixOS PATH) + SSH key only.
  users.mutableUsers = false;
  users.users.root = {
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [ sshPubKey ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin        = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
})).image
