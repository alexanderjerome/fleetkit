# nix/lib

Pure-Nix helper functions shared across the repo — no host config or
derivations of its own.

- `default.nix` — builders for `nixosConfigurations` and Colmena nodes
  (`mkHosts`), plus accessors that abstract the two `hosts.json` formats
  (flat legacy vs rich inventory entries).
- `tf/` — terranix helpers for the provisioning pipeline: stack
  enumeration, Proxmox/XOA resource builders, SOPS-backed provider
  credentials.
- `cloud-init.nix`, `pve-iso.nix` — image/installer composition helpers.
- `grafana.nix` — dashboard/datasource generation helpers.
- `headscale-policy.nix` — derives the tailnet ACL from fleet access data.
- `sops.nix`, `inventory.nix` — secret-path and inventory plumbing.

If logic is needed by more than one module or by both the TF and NixOS
sides, it belongs here.
