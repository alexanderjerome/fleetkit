# nix/run — utility commands for manual use.
#
# Each sub-module exports an attrset of derivations (one per command).
# This file merges them all into a flat namespace; mkFleet exposes the
# result as per-fleet packages (they need the consumer's
# nixosConfigurations / manifest to walk).
#
# Usage:  nix run .#<command>
#
# To add a new command:
#   1. Create nix/run/<topic>.nix returning { pkgs, lib, nixosConfigurations }: { cmd-name = derivation; ... }
#   2. Add it to the imports list below.
#
{ pkgs, lib, nixosConfigurations, nix-topology, fleetCompute }:
let
  call = f: import f { inherit pkgs lib nixosConfigurations; };
in
  call ./services.nix
  // call ./serve-catalog.nix
  // call ./inventory.nix
  // call ./smtp-test.nix
  // call ./pve-ipxe-bundle.nix
  # Topology chart generation (needs nix-topology + the fleet manifest,
  # so it gets its own args beyond the common three).
  // (import ./topology { inherit pkgs lib nix-topology fleetCompute; })
