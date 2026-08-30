{ ... }:

# Cluster-wide network + integration values (schema: fleetkit
# nix/fleet/network/default.nix).

{
  config.fleet.network = {
    dns_domain = "example.lan";
    # Create-time resolvers (cloud-init / CT config): fleet DNS first,
    # public fallback so a fresh host resolves before first deploy.
    dns_servers = [ "192.0.2.100" "1.1.1.1" ];
    # Running-system resolvers: fleet DNS ONLY (split-DNS correctness —
    # a public resolver on the same link leaks internal names).
    internal_resolvers = [ "192.0.2.100" ];
    # Zones pinned to fleet links as systemd-resolved routing domains.
    # Add your public base domain here once fleet DNS serves split-DNS
    # answers for it (e.g. [ "example.lan" "example.dev" ]).
    search_domains = [ "example.lan" ];

    gateway = "192.0.2.1";
    internal_cidr = "192.0.2.0/24";
    lan_gateway = "192.0.2.1";
    lan_cidr = "192.0.2.0/24";
    ntp_server = "192.0.2.100";

    sysadmin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample sysadmin@example.dev";
    sysadmin_key_file = "~/.ssh/sysadmin-key";

    # LDAP directory (only read by hosts that enable infra.sssd).
    ldap = {
      uri = "ldaps://auth.example.dev:636";
      base_dn = "dc=ldap,dc=example,dc=dev";
      user_ou = "ou=users";
      group_ou = "ou=groups";
      ssh_pubkey_attr = "sshPublicKey";
    };
  };
}
