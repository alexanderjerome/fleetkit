{ stackId, backend, fleetModules ? [], ... }:

# Top-level terranix module for a single leaf stack.
#
# Invoked per-stack from mkFleet with
#   import ./nix/tf { stackId = "..."; backend = {...}; fleetModules = [...]; }
# `fleetModules` is the consumer's manifest data (same list mkFleet
# evals); `backend` is the tofu state backend ({ bucket, region ? "us-east-1" }).
# `stackId` flows through module args to resources/ and compute/
# emitters, which filter fleet.* entries matching that `${env}.${stack}`.

let
  slug = builtins.replaceStrings [ "." ] [ "-" ] stackId;
in
{ config, lib, ... }: {
  imports = [
    ../fleet
  ] ++ fleetModules ++ [
    ./providers
    ./resources
    ./compute
  ];

  # stackId flows to every imported module via module args.
  _module.args = {
    inherit stackId;
    _fleetValidated = config.fleet._meta.validated;
  };

  terraform = {
    required_version = ">= 1.10";
    backend.s3 = {
      bucket = backend.bucket;
      key = "tf/${slug}/terraform.tfstate";
      region = backend.region or "us-east-1";
      use_lockfile = true;
      encrypt = true;
    };
  };
}
