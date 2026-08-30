{ config, lib, ... }:

# Xen-Orchestra provider config — inert tonight. Emits nothing unless
# fleet.providers.xen-orchestra has an instance defined AND at least
# one resource references it (see resources/xen-orchestra.nix).
#
# Kept in the providers/ tree so scaffolding is in place for Phase X.

let
  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };
in {
  # Only emit when a XO instance is actually used by some stack.
  # The default `config.fleet.providers.xen-orchestra = {}` case is a
  # no-op — required_providers doesn't list it, no provider block.
  config = lib.mkIf (config.fleet.providers.xen-orchestra != {}) {
    terraform.required_providers.xenorchestra = {
      source = "vatesfr/xenorchestra";
      version =
        let versions = lib.mapAttrsToList (_: c: c.version)
          config.fleet.providers.xen-orchestra;
        in lib.head versions;
    };

    provider.xenorchestra = lib.mapAttrsToList (instance: cfg: {
      alias = instance;
      url = sopsLib.sopsRef cfg.secrets.url;
      token = sopsLib.sopsRef cfg.secrets.token;
      insecure = cfg.insecure;
      retry_mode = "backoff";
      retry_max_time = "5m";
    }) config.fleet.providers.xen-orchestra;
  };
}
