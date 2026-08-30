# nix/modules

Reusable NixOS modules for fleet services — one directory per service
(`caddy/`, `authentik/`, `bitcoin/`, `grafana-stack/`, `coredns/`, …).

`default.nix` is the single import point: every host gets all modules,
but service modules are gated behind `mkEnableOption` and stay inert
unless a host definition enables them. Always-on layers are `core/`
(slim NixOS base: users, SSH, locale, nix gc) and `infra/` (fleet-aware
layer: internal CA, static IPs, SOPS scaffold, alloy, builder cache).

Adding a module: create `nix/modules/<name>/default.nix` and register it
in `nix/modules/default.nix`. Enable it per-host in the host definition
(see `nix/hosts/`).
