{ config, pkgs, lib, ... }:

# Core NixOS module — the configuration.nix + hardware-configuration.nix
# layer of a fleet host. Stays narrow on purpose: users, SSH, locale,
# nix settings, single-DHCP eth0. Everything fleet-aware (internal CA,
# builder cache, alloy, SOPS scaffold, fleet's static-IP wiring) lives
# in ./fleet-member.nix. Substrate-specific boot/kernel config lives in
# ../platform/.
#
# A fleet host's final config is: core + platform + infra + services.
# A bootstrap template (../platform/xcpng/bootstrap-image.nix) is just
# core + platform — enough to come up, get DHCP, accept Colmena.

let
  # Shared operator keys until per-user SSH keys land via SOPS (see
  # INFRA-18). Today every operator credential rides the same key set
  # (fleet.settings.adminSshKeys); the user names (sysadmin / colmena /
  # dev) exist so the keys can rotate independently once SOPS
  # users.yaml is in place. The `or []` keeps this module importable
  # outside the fleet schema (e.g. bootstrap images), where no keys
  # default to none.
  adminSshKeys = config.fleet.settings.adminSshKeys or [];

  defaultLocale = "en_US.UTF-8";
in
{
  imports = [
    ../platform
  ];

  # ── Locale ─────────────────────────────────────────────────────
  # Framework default only — a host (or a catalog preset) may set its own
  # zone without mkForce.
  time.timeZone = lib.mkDefault "UTC";

  i18n = {
    defaultLocale = defaultLocale;
    extraLocaleSettings = {
      LC_ADDRESS = defaultLocale;
      LC_IDENTIFICATION = defaultLocale;
      LC_MEASUREMENT = defaultLocale;
      LC_MONETARY = defaultLocale;
      LC_NAME = defaultLocale;
      LC_NUMERIC = defaultLocale;
      LC_PAPER = defaultLocale;
      LC_TELEPHONE = defaultLocale;
      LC_TIME = defaultLocale;
    };
  };

  # ── Users ──────────────────────────────────────────────────────
  # Three normal users, distinct keys-when-we-have-them. Root has no
  # SSH access; break-glass via console only. Each user is in wheel
  # with passwordless sudo (we're in active dev — INFRA-18 will
  # introduce SOPS-managed passwords + per-user keys for blast-radius
  # separation).
  users.mutableUsers = false;

  users.users.sysadmin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = adminSshKeys;
    shell = pkgs.bash;
  };

  # colmena — used by the Colmena deploy tool. Separate user so the
  # key can rotate independently of sysadmin's. Full sudo (no
  # `command=` restriction) until INFRA-18 lets us scope it down.
  users.users.colmena = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = adminSshKeys;
    shell = pkgs.bash;
  };

  # dev — shared developer account. Anyone on the team SSH-ing in to
  # check process / system state lands here. Full sudo for now (active
  # dev phase); rotate independently of sysadmin / colmena.
  users.users.dev = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = adminSshKeys;
    shell = pkgs.bash;
  };

  # root — SSH stays open with the sysadmin key for now. nix/lib/default.nix
  # targets `root` for every Colmena push; closing root SSH here would
  # lock Colmena out the moment this closure activates on an existing
  # fleet host (or on any production VM cloned from the v10 template).
  # The right migration is: switch Colmena targetUser to `colmena` +
  # sudo, then close root SSH. Tracked as a follow-up under INFRA-14.
  users.users.root = {
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = adminSshKeys;
  };

  security.sudo.wheelNeedsPassword = false;

  # ── SSH ────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      # prohibit-password = key-only root login (matches the
      # operational pattern Colmena depends on today). mkDefault so a
      # future per-host lockdown can flip it without forking core.
      PermitRootLogin = lib.mkDefault "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # Pin dbus to the broker implementation, matching what the NixOS LXC
  # template defaults to. Without this, the template ships broker but
  # the fleet config evaluated to classic dbus, and `nixos-rebuild
  # switch` refused to swap the dbus implementation in-place
  # (switchInhibitors check). Pinning fleet-wide keeps both sides
  # aligned and avoids the bootstrap-needs-reboot dance. See ADR-021
  # Phase 3.d for the incident.
  services.dbus.implementation = "broker";

  # ── Packages ───────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    curl git jq tree vim htop wget gnupg
    dig tcpdump
  ];

  # ── Networking: single DHCP eth0 ───────────────────────────────
  # Core ships exactly one interface, DHCP. Anything fleet-aware
  # (static internal IP on eth1, fleet DNS, the internal domain) is
  # layered on top by ./fleet-member.nix once the host is in the fleet. A
  # fresh bootstrap-template clone with just core+platform comes up
  # DHCP-on-eth0 and is reachable via that DHCP lease for the first
  # Colmena push.
  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    networkConfig.DHCP = "ipv4";
    dhcpV4Config = { UseDNS = true; UseHostname = false; };
  };

  # Don't block boot waiting for all NICs to be online — the default
  # behaviour waits for every matched interface to be routable, hitting
  # the 120 s timeout on multi-NIC hosts. Any-one online is enough.
  systemd.network.wait-online.anyInterface = lib.mkDefault true;
  systemd.network.wait-online.timeout = lib.mkDefault 30;

  # ── fstrim ─────────────────────────────────────────────────────
  # INFRA-188: nearly every fleet guest sits on an LVM-thin pool (pve-db,
  # pve-platform, ...). Deleted blocks inside a guest stay allocated in the
  # pool until trimmed — vm-204 alone held ~40G of dead blocks while the
  # pve-db pool ran at 91% (thin-pool exhaustion kills every guest on the
  # pool at once, INFRA-164). Weekly trim returns freed blocks to the pool.
  # On volumes without discard support the FITRIM ioctl fails per-mount and
  # the unit logs + moves on — safe fleet-wide.
  services.fstrim.enable = true;

  # ── SOPS key directory ─────────────────────────────────────────
  # /var/lib/sops-nix is where sops-nix decrypts secrets to. Created
  # here (not in ./fleet-member.nix) so the directory exists even before
  # infra-level SOPS scaffolding lands — the bootstrap template never
  # imports fleet-member.nix but does inherit core.
  systemd.tmpfiles.rules = [ "d /var/lib/sops-nix 0700 root root -" ];

  # ── Nix ────────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Per-host disks are tight (netgate at 24 GB, app-* at 2 GB), so
  # generations accumulate across deploys and ENOSPC the rootfs
  # mid-copy ("copying N paths..." → die). Two-tier defense:
  #   1. Daily GC drops generations older than 7 days.
  #   2. min-free / max-free trigger an emergency GC inside the
  #      nix-daemon when free space dips below 1 GiB during a copy
  #      or build, freeing until 5 GiB is available again.
  # The second tier is what protects in-flight `colmena apply` from
  # dying on tight hosts.
  #
  # INFRA-108: tightened weekly/14d → daily/7d. backend-v2 (16 G root,
  # deployed multiple times/day) accumulated 5.8 GiB / ~800k inodes of old
  # generations under the 14d window and tripped BOTH disk-warning and
  # disk-critical (89% bytes, 98% inodes). The emergency min-free tier
  # didn't help: it triggers only below 1 GiB free (we sat at 1.7 G) and
  # does nothing for inode exhaustion. Daily/7d keeps high-churn hosts lean
  # while still leaving a week of rollback.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
    randomizedDelaySec = "1h";
  };
  nix.settings.min-free = 1024 * 1024 * 1024;     # 1 GiB
  nix.settings.max-free = 5 * 1024 * 1024 * 1024; # 5 GiB

  system.stateVersion = "25.11";
}
