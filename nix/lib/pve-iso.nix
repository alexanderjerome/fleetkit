{ pkgs, lib }:

# ADR-025 Phase 1 — PVE auto-install answer.toml renderer.
#
# NOTE: this file used to contain a customised-ISO derivation
# (proxmox-auto-install-assistant prepare-iso --fetch-from http).
# That approach was abandoned 2026-05-29 in favour of partition-mode:
# we now use the stock PVE installer ISO unmodified, and ship the
# answer.toml on a tiny separate disk partition labeled `proxmox-ais`
# attached to each PVE VM at install time. Per the official docs at
# https://pve.proxmox.com/wiki/Automated_Installation, the installer
# scans attached block devices for a partition with that label, reads
# its answer.toml, and proceeds unattended.
#
# Renderer kept here as a pure-Nix function for local validation and
# tests. The deployer (nix/pkgs/_launcher/fleet_launcher/pve_install.py)
# has an equivalent Python renderer driving the actual per-VM disk
# build. Keep the two in sync.

let
  defaultDns = "1.1.1.1";
in {
  # ── answer.toml renderer ─────────────────────────────────────────
  # Field names are kebab-case per the PVE schema. NIC selection uses
  # ID_NET_NAME_MAC which maps to the udev-resolved interface name
  # derived from the NIC's MAC.
  mkAnswer = {
    hostname,
    # Fully-qualified name, e.g. "${hostname}.${config.fleet.settings.domain.internal}".
    fqdn,
    # Notification address, e.g. "ops@${config.fleet.settings.domain.base}".
    mailto,
    mgmt_ip,
    mgmt_cidr,
    gateway,
    dns ? defaultDns,
    mac,
    root_password_hashed,
    root_ssh_keys,
  }:
    let
      enxName = "enx" + builtins.replaceStrings [":"] [""] (lib.toLower mac);
    in pkgs.writeText "answer-${hostname}.toml" ''
      # Schema reference: https://pve.proxmox.com/wiki/Automated_Installation
      # Field names are kebab-case; the assistant rejects snake_case.

      [global]
      keyboard             = "en-us"
      country              = "us"
      fqdn                 = "${fqdn}"
      mailto               = "${mailto}"
      timezone             = "UTC"
      root-password-hashed = "${root_password_hashed}"
      root-ssh-keys        = [ ${
        lib.concatStringsSep ", " (map (k: ''"${k}"'') root_ssh_keys)
      } ]
      reboot-on-error      = false

      [network]
      source                 = "from-answer"
      cidr                   = "${mgmt_cidr}"
      dns                    = "${dns}"
      gateway                = "${gateway}"
      filter.ID_NET_NAME_MAC = "${enxName}"

      [disk-setup]
      filesystem = "ext4"
      disk-list  = ["sda"]
    '';
}
