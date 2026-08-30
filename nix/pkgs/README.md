# nix/pkgs

Custom package derivations not available (or not suitable as-is) in
nixpkgs. One directory per package:

- `_launcher/` — the `fleet` CLI itself: Python package wrapping
  all infrastructure operations (tofu, colmena, SOPS, inventory, remote
  exec). This is the primary operator entry point for the repo.
- `cv4pve-cli/` — Proxmox cv4pve tooling (.NET single-file binary,
  patched for nix).
- `ordpg/` — ord-with-postgres indexer build.
- `xo-grafana-exporter/` — Prometheus exporter for the XCP-ng tier via
  the Xen Orchestra REST API (INFRA-40). Stdlib-only Python; exists
  because our XOA edition has no OpenMetrics plugin and we hold no dom0
  credentials, so XO REST is the only metrics surface.

Packages here are wired into the flake's `packages` output and consumed
by modules/hosts; they are built locally, not pulled from a channel.
