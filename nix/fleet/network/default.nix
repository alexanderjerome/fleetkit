{ config, lib, ... }:

# Cluster-wide network + integration config — schema only. Values are
# supplied by the consumer repo (fleetkit is schema-only here).
#
# Consumed by the sssd NixOS module, Colmena, the dev-VM cloud-init
# renderer, and every host's systemd-networkd config (via core.nix).

{
  options.fleet.network = {
    ldap = {
      uri = lib.mkOption {
        type = lib.types.str;
        description = "Authentik LDAP outpost URI (used by sssd + Proxmox realm).";
      };
      base_dn = lib.mkOption {
        type = lib.types.str;
      };
      user_ou = lib.mkOption {
        type = lib.types.str;
      };
      group_ou = lib.mkOption {
        type = lib.types.str;
      };
      ssh_pubkey_attr = lib.mkOption {
        type = lib.types.str;
        description = "LDAP attribute sssd reads for SSH public keys.";
      };
    };

    dns_servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        BOOTSTRAP/CREATE-TIME resolver list only: written into every VM's
        cloud-init network-config drive and the PVE container/VM dnsConfig
        at create time (nix/lib/tf/proxmox.nix). Primary is the fleet DNS
        host (CoreDNS); a public resolver (e.g. 1.1.1.1) as fallback lets a
        fresh host resolve (nix cache, etc.) before its first Colmena deploy
        even if fleet DNS is briefly unreachable.

        NOTE: this list is deliberately NOT used for the running
        systemd-networkd link DNS — see `internal_resolvers` and INFRA-107.
        A public resolver on the same link as the fleet routing domains
        causes systemd-resolved's sticky per-link failover to leak internal
        names to public DNS (which may serve a real public zone of the same
        name → WAN IP → un-hairpinnable), taking hosts offline.
      '';
    };

    internal_resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Resolver(s) for the RUNNING systemd-networkd link config on fleet
        hosts (nix/modules/infra/base/fleet-member.nix). Must be fleet-DNS-only
        (CoreDNS) — never a public resolver. The `search_domains` zones are
        pinned to the link as routing domains, and the internal split-DNS
        answers (e.g. vpn.<base domain> → an internal IP) are only correct
        from fleet DNS; a public fallback on the same link would let
        systemd-resolved's sticky failover serve the public DNS answer
        (the WAN IP, which many routers can't hairpin from the LAN). External
        names still resolve: fleet DNS forwards them, and a fleet-DNS outage
        falls back (non-stickily) to systemd-resolved's built-in global
        FallbackDNS for external names only. (INFRA-107)
      '';
    };

    dns_domain = lib.mkOption {
      type = lib.types.str;
      description = "Internal search domain.";
    };

    search_domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "example.pve" "example.dev" ];
      description = ''
        DNS zones pinned as systemd-resolved routing domains on single-NIC
        fleet links (nix/modules/infra/base/fleet-member.nix), so queries
        for every fleet-served zone go to fleet DNS — including public
        zones the fleet answers with split-DNS internal IPs. Defaults to
        [ dns_domain ]; add the public base domain (and any other
        fleet-served zones) when fleet DNS serves split-DNS answers for
        them. (INFRA-107)
      '';
    };

    sysadmin_ssh_key = lib.mkOption {
      type = lib.types.str;
      description = "sysadmin SSH public key — baked into every CT/VM by nix/images/bootstrap.nix and referenced by Colmena.";
    };

    sysadmin_key_file = lib.mkOption {
      type = lib.types.str;
      default = "~/.ssh/sysadmin-key";
      description = ''
        Operator-local path to the sysadmin SSH *private* key. Single source of
        truth: the devShell (nix/shell.nix) loads it into ssh-agent and exports
        it as SK_SYSADMIN_KEY_FILE; the terranix ansible emitter reads it as
        ansible_ssh_private_key_file; pure-Ansible inventory reads the env var.
        A leading `~` is expanded by each consumer (Ansible expanduser; the
        devShell expands it for bash).
      '';
    };

    # NOTE: `dev_users` was removed when the dev-VM identity registry
    # landed in fleet.access.users. Cloud-init's user creation now
    # reads from `fleet.access.users` via `ref` lookups in
    # `cloud_init.users[*].ref` on each VM entry.

    gateway = lib.mkOption {
      type = lib.types.str;
      description = "Internal network gateway (typically a dedicated router host on the internal bridge; ADR-021 Phase 1.b).";
    };

    internal_cidr = lib.mkOption {
      type = lib.types.str;
      description = "Internal service network CIDR (vmbr1 bridge).";
    };

    lan_gateway = lib.mkOption {
      type = lib.types.str;
      description = ''
        LAN gateway (UDM router). Used by single-NIC hosts on vmbr0
        (network_mode = "single-external", e.g. landing-page) and by
        the dual-NIC + WAN-side branches of `router`/`netgate`.
      '';
    };

    lan_cidr = lib.mkOption {
      type = lib.types.str;
      description = "LAN CIDR (vmbr0 bridge).";
    };

    ntp_server = lib.mkOption {
      type = lib.types.str;
      description = ''
        Fleet NTP server IP. Every NixOS host's chrony client (wired
        in nix/modules/infra/base/core/default.nix) targets this address. The
        host running the chrony server overrides its own
        `services.chrony.servers` to public upstream pools.
      '';
    };
  };

  # Generic default: pin only the internal search domain. Consumers with
  # split-DNS public zones extend the list in their network.nix.
  config.fleet.network.search_domains =
    lib.mkDefault [ config.fleet.network.dns_domain ];
}
