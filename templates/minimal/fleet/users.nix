{ ... }:

# Identity registry + app group bindings (schema: fleetkit
# nix/fleet/users/default.nix). SSH keys land via cloud-init/LDAP;
# groups drive app access policies.

{
  config.fleet.access.users = {
    operator = {
      email = "operator@example.dev";
      ssh_keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample operator@example.dev" ];
      groups = [ "platform-admins" ];
    };
  };

  config.fleet.access.apps = { };
}
