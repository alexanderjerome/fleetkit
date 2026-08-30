{ config, lib, ... }:

# cloudflare/cloudflare provider config — single provider block (no alias
# needed; Cloudflare resources bind to zones by name, not provider alias).

let
  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };
  instances = config.fleet.providers.cloudflare;
in {
  config = lib.mkIf (instances != {}) {
    terraform.required_providers.cloudflare = {
      source = "cloudflare/cloudflare";
      version = lib.head (lib.mapAttrsToList (_: c: c.version) instances);
    };

    provider.cloudflare = {
      api_token = sopsLib.sopsRef
        (lib.head (lib.mapAttrsToList (_: c: c.secrets.api_token) instances));
    };
  };
}
