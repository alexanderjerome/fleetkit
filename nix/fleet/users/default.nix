{ config, lib, ... }:

# Layer-3 (web/OIDC) access policy + identity registry — schema only.
# Values are supplied by the consumer repo (fleetkit is schema-only here).
#
# Source of truth for:
#   1. Which Authentik groups are allowed to log in to each application
#      (`fleet.access.apps`).
#   2. Which humans/service-accounts exist in the fleet, what groups
#      they're in, and what SSH keys they own (`fleet.access.users`).
#
# Consumed by:
#   - nix/modules/authentik/blueprints.nix → emits authentik_core.user
#     entries with attributes.sshPublicKey, so NixOS hosts (via SSSD/LDAP)
#     and the Proxmox LDAP realm see the same identity + key. Also
#     emits expressionpolicy + policybinding for each app↦group entry.
#   - cloud-init renderCloudInitSnippet → resolves cloud_init.users[*].ref
#     into a full user entry for Debian dev VMs.
#   - nix run .#access-audit (prints the three-layer matrix per host)
#
# Rotating an SSH key: edit fleet.access.users.<name>.ssh_keys → Nix
# eval propagates to Authentik blueprint (NixOS via SSSD picks up via
# LDAP cache) AND to every dev-VM cloud-init snippet (next deploy).

let
  userOpts = lib.types.submodule {
    options = {
      email = lib.mkOption {
        type = lib.types.str;
        description = "Primary email address. Required by Authentik user.email.";
      };
      ssh_keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "SSH public keys. Published as Authentik attributes.sshPublicKey for SSSD; injected into dev-VM cloud-init.";
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Authentik groups (LDAP-side membership). NOT the same as Linux groups on a VM — those are declared on cloud_init.users[*].extra_groups.";
      };
      type = lib.mkOption {
        type = lib.types.enum [ "internal" "service_account" ];
        default = "internal";
        description = "Maps to Authentik's user.type field.";
      };
    };
  };
in
{
  options.fleet.access = {
    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (lib.types.listOf lib.types.str));
      default = {};
      description = "OIDC application slug → list of Authentik groups allowed to log in (null = any authenticated user).";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = {};
      description = "Fleet identity registry. Keyed by Authentik username.";
    };
  };
}
