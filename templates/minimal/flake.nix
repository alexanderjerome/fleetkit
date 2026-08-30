{
  # Minimal fleetkit consumer. Copy with:
  #   nix flake init -t <fleetkit-ref>#minimal
  #
  # Layout:
  #   flake.nix        — this file: mkFleet wiring + output re-export
  #   fleet/           — YOUR manifest: settings, providers, network,
  #                      users, dns data, and one file per host
  #   fleet.toml       — CLI-side settings (bucket, domains, key paths)
  #   nix/secrets/     — SOPS store (create with `sops nix/secrets/secrets.yaml`)

  inputs = {
    fleetkit.url = "github:REPLACE-ME/fleetkit";
    nixpkgs.follows = "fleetkit/nixpkgs";
  };

  outputs = { self, fleetkit, nixpkgs }:
  let
    fleet = fleetkit.lib.mkFleet {
      # Everything environment-specific enters through these arguments.
      modules = [ ./fleet ];
      backend = {
        bucket = "REPLACE-ME-tofu";     # S3(-compatible) tofu state bucket
        # region = "us-east-1";
      };
      # NixOS modules applied to every host — app flakes, sops defaults,
      # module-args. Start empty.
      globalModules = [ ];
      # Per-host flake-input modules, e.g. { myhost = [ inputs.microvm.nixosModules.host ]; }
      hostExtraModules = { };
    };
  in
  {
    inherit (fleet) colmena nixosConfigurations fleetManifest fleetAccess;

    packages.x86_64-linux = fleet.packages // {
      # The operator CLI, re-exported so `nix run .#fleet` works here.
      fleet = fleetkit.packages.x86_64-linux.fleet;
      default = fleetkit.packages.x86_64-linux.fleet;
    };

    devShells.x86_64-linux.default = fleetkit.devShells.x86_64-linux.default;
  };
}
