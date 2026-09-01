{ ... }:

# The same host shape authored ADR-096 v2-style: the machine lives IN the
# provider tree, and its NixOS config and secrets ride along as facets —
# one declaration instead of three parallel namespaces. Both styles
# coexist; pick one per machine. This file doubles as the framework's own
# regression coverage: the example-fleet check forces this host's closure
# and asserts the lift, so the v2 path cannot silently rot.

{
  config.fleet.providers.proxmox.main.nodes.pve1.resources.lxc.example-v2 = {
    env = "platform"; stack = "core";
    vm_id = 102;
    tags = [ "example" ];
    ip = ""; internal_ip = "192.0.2.102";
    cpu_cores = 1; memory_mb = 512; swap_mb = 256;
    root_disk_datastore = "local-lvm";
    network_mode = "single-internal";
    notes = "Example NixOS LXC, v2-authored — replace me.";

    nixos = { helpers, ... }: {
      infra.networking.singleInterface = true;
      # The secrets facet below routes into ./secrets/example-v2.json,
      # which ships as a placeholder (real deployments re-encrypt with
      # `fleet secrets init` + sops). Skip sops-nix's file validation so
      # the template evaluates before any real key material exists.
      sops.validateSopsFiles = false;
    };

    secrets = {
      file = ../secrets/example-v2.json;
      instances.default = {
        envPrefix = "EXAMPLE";
        secrets.api_token = { owner = "root"; };
      };
    };
  };
}
