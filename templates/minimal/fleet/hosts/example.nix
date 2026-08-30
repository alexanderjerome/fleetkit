{ ... }:

# One file per host: the provisioning entry (fleet.compute.<name>) and,
# for NixOS guests, the OS config (fleet.hostsRegistry.<name>). Editing
# a host is a single-file change.

{
  config.fleet.compute.example = {
    env = "platform"; stack = "core";
    provider_instance = "proxmox.main";
    kind = "container";
    vm_id = 101;
    node = "pve1";
    tags = [ "example" ];
    ip = ""; internal_ip = "192.0.2.101";
    cpu_cores = 2; memory_mb = 1024; swap_mb = 512;
    root_disk_datastore = "local-lvm";
    network_mode = "single-internal";
    features = { nesting = true; fuse = false; keyctl = false; };
    notes = "Example NixOS LXC — replace me.";
  };

  config.fleet.hostsRegistry.example = { helpers, ... }: {
    infra.networking.singleInterface = true;

    # Fleet services are enabled per host under the strata namespace,
    # infra.<stratum>.<module> — e.g.:
    #   infra.data.postgresql.enable = true;
    #   infra.ingress.enable = true;
    #   infra.observability.stack.enable = true;
    # See the "Infra modules" chapter of the docs for the full catalog.
  };
}
