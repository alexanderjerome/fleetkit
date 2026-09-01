{ ... }:

# Your fleet manifest — the single entry point mkFleet evals.
# Everything under this directory is DATA; the schema and validators
# live in fleetkit (nix/fleet/).

{
  imports = [
    ./settings.nix
    ./network.nix
    ./providers.nix
    ./users.nix
    ./dns.nix
    ./hosts/example.nix
    ./hosts/example-v2.nix   # same host shape, ADR-096 provider-tree style
  ];
}
