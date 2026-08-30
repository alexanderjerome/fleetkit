{ ... }:

# Cluster-wide network + integration values (schema: fleetkit
# nix/fleet/network/default.nix).
#
# MINIMUM-VIABLE PRINCIPLE: only `sysadmin_ssh_key` is required (the
# provisioning layer bakes it into every CT/VM so hosts are reachable).
# The active values below are the small realistic core for a host with
# egress; delete them and the fleet still evaluates — you just get a
# routeless, resolver-less guest. Everything else is commented until
# the feature that consumes it exists.

{
  config.fleet.network = {
    # REQUIRED — baked into every CT/VM at create time; Colmena reaches
    # fresh hosts with it.
    sysadmin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample sysadmin@example.dev";

    # Default route for internal-bridge hosts (a router LXC or your LAN
    # gateway). Omit for a fully isolated lab fleet.
    gateway = "192.0.2.1";

    # ── Uncomment as the fleet grows ──────────────────────────────────

    # # Internal DNS zone + resolvers, once you run fleet DNS (coredns):
    # dns_domain = "example.lan";
    # # Running-system resolvers: fleet DNS ONLY (split-DNS correctness —
    # # a public resolver on the same link leaks internal names).
    # internal_resolvers = [ "192.0.2.100" ];
    # # Create-time resolvers (cloud-init / CT config): fleet DNS first,
    # # public fallback so a fresh host resolves before first deploy.
    # # Default: [ "1.1.1.1" "9.9.9.9" ].
    # dns_servers = [ "192.0.2.100" "1.1.1.1" ];
    # # Zones pinned to fleet links as systemd-resolved routing domains.
    # # Defaults to [ dns_domain ]; add your public base domain once
    # # fleet DNS serves split-DNS answers for it.
    # search_domains = [ "example.lan" "example.dev" ];

    # # LAN-side (vmbr0) shapes — only for single-external hosts and
    # # router/netgate VMs:
    # lan_gateway = "192.0.2.1";
    # lan_cidr = "192.0.2.0/24";      # informational (CLI parity)
    # internal_cidr = "192.0.2.0/24"; # informational (CLI parity)

    # # Fleet NTP server, once one host serves chrony:
    # ntp_server = "192.0.2.100";

    # # Operator-local path to the sysadmin private key (devShell/Ansible).
    # # Default: "~/.ssh/sysadmin-key".
    # sysadmin_key_file = "~/.ssh/sysadmin-key";

    # # LDAP directory (only read by hosts that enable infra.auth.sssd):
    # ldap = {
    #   uri = "ldaps://auth.example.dev:636";
    #   base_dn = "dc=ldap,dc=example,dc=dev";
    #   # user_ou / group_ou / ssh_pubkey_attr default to
    #   # "ou=users" / "ou=groups" / "sshPublicKey".
    # };
  };
}
