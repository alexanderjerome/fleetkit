{ config, lib, ... }:

# Cluster-wide network + integration config — schema only. Values are
# supplied by the consumer repo (fleetkit is schema-only here).
#
# Consumed by the sssd NixOS module, Colmena, the dev-VM cloud-init
# renderer, and every host's systemd-networkd config (via core.nix).

let
  prefixOf = cidr: fallback:
    if cidr == null then fallback
    else lib.toInt (lib.last (lib.splitString "/" cidr));
in
{
  options.fleet.network = {
    ldap = {
      uri = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "ldap://auth.example.internal:389";
        description = "Authentik LDAP outpost URI (used by sssd + Proxmox realm). null ⇒ no LDAP directory; required (asserted) when infra.auth.sssd is enabled.";
      };
      base_dn = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "dc=ldap,dc=example,dc=com";
        description = "LDAP base DN for user/group searches. null ⇒ no LDAP directory; required (asserted) when infra.auth.sssd is enabled.";
      };
      user_ou = lib.mkOption {
        type = lib.types.str;
        default = "ou=users";
        description = "OU holding user entries, relative to base_dn.";
      };
      group_ou = lib.mkOption {
        type = lib.types.str;
        default = "ou=groups";
        description = "OU holding group entries, relative to base_dn.";
      };
      ssh_pubkey_attr = lib.mkOption {
        type = lib.types.str;
        default = "sshPublicKey";
        description = "LDAP attribute sssd reads for SSH public keys.";
      };
    };

    dns_servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "9.9.9.9" ];
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
      default = [ ];
      example = [ "192.0.2.103" ];
      description = ''
        [] (default) ⇒ no fleet DNS: fleet links carry no per-link DNS
        and hosts fall back to systemd-resolved defaults. Set to your
        CoreDNS host(s) once fleet DNS exists.

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
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.internal";
      description = "Internal search domain. null ⇒ no internal zone: fleet links pin no search domain, provisioned guests get no create-time DNS domain, and infra.network.dhcp (asserted) needs an explicit domain.";
    };

    search_domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      defaultText = lib.literalExpression "lib.optional (config.fleet.network.dns_domain != null) config.fleet.network.dns_domain";
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
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExa sysadmin@example.com";
      description = "sysadmin SSH public key — baked into every CT/VM by nix/images/bootstrap.nix and referenced by Colmena. REQUIRED BY THE PROVISIONING LAYER — rendering any provider stack (image bake + create-time key injection) forces this option.";
    };

    sysadmin_key_file = lib.mkOption {
      type = lib.types.str;
      default = "~/.ssh/sysadmin-key";
      description = ''
        Operator-local path to the sysadmin SSH *private* key. Single source of
        truth: the devShell (nix/shell.nix) loads it into ssh-agent; the
        terranix ansible emitter (nix/tf/compute/ansible.nix) and the
        launcher's generated inventory both read it as
        ansible_ssh_private_key_file. A leading `~` is expanded by each
        consumer (Ansible expanduser; the devShell expands it for bash).

        The framework exports no environment variable for this. A consumer
        with a hand-written Ansible inventory that resolves the key from the
        environment should export it as FLEET_SYSADMIN_KEY_FILE (INFRA-218 —
        this description previously named SK_SYSADMIN_KEY_FILE, an export
        that only ever existed in consumer-side shell.nix, never here).
      '';
    };

    # NOTE: `dev_users` was removed when the dev-VM identity registry
    # landed in fleet.access.users. Cloud-init's user creation now
    # reads from `fleet.access.users` via `ref` lookups in
    # `cloud_init.users[*].ref` on each VM entry.

    gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.0.2.1";
      description = "Internal network gateway (typically a dedicated router host on the internal bridge; ADR-021 Phase 1.b). null ⇒ internal-bridge hosts get no default route (isolated lab fleets); set it for any fleet that expects egress.";
    };

    internal_cidr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.0.2.0/24";
      description = "Internal service network CIDR (vmbr1 bridge). Informational — no framework module consumes it today; kept for CLI/fleet.toml parity.";
    };

    lan_gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "198.51.100.1";
      description = ''
        LAN gateway (UDM router). Used by single-NIC hosts on vmbr0
        (network_mode = "single-external", e.g. landing-page) and by
        the dual-NIC + WAN-side branches of `router`/`netgate`.
        null ⇒ those host shapes get no WAN-side default route; set it
        before declaring any vmbr0-facing host.
      '';
    };

    lan_cidr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "198.51.100.0/24";
      description = "LAN CIDR (vmbr0 bridge). Informational — no framework module consumes it today; kept for CLI/fleet.toml parity.";
    };

    # Prefix lengths appended to the BARE `internal_ip` / `ip` of the
    # legacy network modes (and to the NixOS-side link config). They used
    # to be a hard-coded /24 in nix/lib/tf/proxmox.nix and fleet-member.nix.
    # Derived from the CIDRs when those are set, else 24 — identical
    # output for fleets that never set them. `network_mode = "declared"`
    # carries an explicit prefix per interface and ignores these.
    internal_prefix_len = lib.mkOption {
      type = lib.types.ints.between 0 32;
      default = prefixOf config.fleet.network.internal_cidr 24;
      defaultText = lib.literalExpression "prefix length of fleet.network.internal_cidr, else 24";
      example = 22;
      description = "Prefix length for the internal bridge (vmbr1) network: appended to every bare `internal_ip` by the legacy network modes and by the fleet-member networkd config. Default: taken from `internal_cidr`, else 24.";
    };

    lan_prefix_len = lib.mkOption {
      type = lib.types.ints.between 0 32;
      default = prefixOf config.fleet.network.lan_cidr 24;
      defaultText = lib.literalExpression "prefix length of fleet.network.lan_cidr, else 24";
      example = 24;
      description = "Prefix length for the LAN bridge (vmbr0) network: appended to every bare `ip` by the single-external / dual / router / netgate paths and by the fleet-member networkd config. Default: taken from `lan_cidr`, else 24.";
    };

    ntp_server = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.0.2.101";
      description = ''
        null ⇒ no fleet NTP: non-container hosts keep chrony disabled
        and rely on their own time sources.

        Fleet NTP server IP. Every NixOS host's chrony client (wired
        in nix/modules/infra/base/core/default.nix) targets this address. The
        host running the chrony server overrides its own
        `services.chrony.servers` to public upstream pools.
      '';
    };
  };

  # Generic default: pin only the internal search domain (none when no
  # internal zone is declared). Consumers with split-DNS public zones
  # extend the list in their network.nix.
  config.fleet.network.search_domains =
    lib.mkDefault (lib.optional (config.fleet.network.dns_domain != null)
      config.fleet.network.dns_domain);
}
