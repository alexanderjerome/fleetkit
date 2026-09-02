{ stackId, backend, fleetModules ? [], fleetLib ? null, ... }:

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

  # Per-stack backend override. The backend block is already emitted per
  # stack (the S3 key is "tf/<slug>/…"), so letting one stack choose a
  # different backend costs nothing structurally and buys a lot: a fleet
  # whose shared bucket is unreachable can still provision NEW stacks on
  # local state, and stacks that must not depend on in-fleet storage (the
  # one holding the object store itself) can be pinned elsewhere.
  #
  # Only meaningful for a stack with no existing remote state, or one
  # deliberately migrated: pointing an existing stack at an empty backend
  # makes tofu read its whole inventory as "not created yet". Consumers
  # are expected to treat an override as a deliberate, recorded act.
  effBackend = (removeAttrs backend [ "perStack" ])
    // (backend.perStack.${slug} or { });
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
    # THIRD eval path for the consumer's manifest modules. mkFleet injects
    # fleetLib into the manifest eval and into every NixOS host; terranix
    # evaluates the SAME modules again here, so a consumer manifest module
    # that uses fleetLib (a Grafana Cloud check, a vaultwarden allowlist)
    # fails with "attribute 'fleetLib' missing" unless it is injected here
    # too. Found the hard way: colmena and the devshell both stayed green
    # while `nix build .#tf-<stack>` broke.
    inherit fleetLib;
    _fleetValidated = config.fleet._meta.validated;
  };

  terraform = {
    required_version = ">= 1.10";
  } // (
    # "local" keeps terraform.tfstate in the stack's working dir
    # (.tf/<slug>/ — the tofu chdir), so no bucket or cloud creds are
    # needed; the state then lives only on the applying machine.
    if (effBackend.type or "s3") == "local" then {
      backend.local = { path = "terraform.tfstate"; };
    } else {
      backend.s3 = {
        bucket = effBackend.bucket;
        key = "tf/${slug}/terraform.tfstate";
        region = effBackend.region or "us-east-1";
        use_lockfile = true;
        encrypt = true;
      };
    });
}
