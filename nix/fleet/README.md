# nix/fleet

The fleet manifest — single source of truth for every container, VM, and
shared resource in the deployment (schema v2, SKRYBITDEV-599).

Both halves of the pipeline read from here:

1. **Provisioning** — `nix/tf/` emitters turn fleet entries into
   Terraform JSON, one tfstate per `<env>.<stack>` leaf.
2. **NixOS deploys** — `mkHosts` in `nix/lib/` turns the same entries
   into Colmena nodes; `hosts.json` is regenerated from it (never edit
   that file by hand).

Layout: `default.nix` (schema + validators: unique vm_id, `protect`
flags, `_meta.validated` gate), `compute.nix` (container/VM entries),
`resources.nix` (non-compute resources), and submodules `dns/`,
`network/`, `providers/`, `users/` for per-domain declarations.

Per-host compute entries themselves live in `nix/hosts/` and merge into
`config.fleet.compute.*`; this directory holds the schema, validation,
and fleet-wide data.
