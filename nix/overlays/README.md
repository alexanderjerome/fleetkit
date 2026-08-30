# nix/overlays

Nixpkgs overlays — targeted overrides applied on top of the pinned
nixpkgs before packages/modules consume it.

Currently:

- `crates-ua/` — backported `fetchCargoVendor` machinery (vendoring
  helper + workspace-value rewriting) for Rust packages whose lockfiles
  the pinned nixpkgs can't handle.

Use an overlay when an upstream package needs patching or a newer
fetcher; use `nix/pkgs/` instead when the package doesn't exist in
nixpkgs at all.
