# nix/run

Ad-hoc utility commands exposed as flake apps — run with `nix run .#<command>`.

Each `<topic>.nix` file exports an attrset of command derivations (service
catalog, inventory dump, PVE OIDC setup, deploy dashboard, ord backfill,
SMTP test, access audit, iPXE bundle, …). `default.nix` merges them all
into one flat namespace for `flake.nix`.

These are operator tools for manual one-off use, not part of host
configuration. To add a command: create `nix/run/<topic>.nix` returning
`{ pkgs, lib, nixosConfigurations }: { cmd-name = drv; }` and add it to
the imports in `default.nix`.
