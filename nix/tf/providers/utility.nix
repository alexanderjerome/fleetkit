{ config, lib, ... }:

# Config-less utility providers (hashicorp/random, /tls, /time,
# /cloudinit). These need ONLY a `required_providers` entry — no
# `provider "<name>" {}` block, no secrets, no state. Their resources
# (random_password, tls_cert_request, time_sleep, cloudinit_config, …)
# work with zero provider configuration.
#
# Like the cloudflare/sops emitters, this fires into every stack's
# config.tf.json whenever the instance is declared, so `tofu init`
# resolves them everywhere. Cheap — these are tiny providers.

let
  p = config.fleet.providers;
  mkReq = inst: { source = inst.source; version = inst.version; };
in {
  config = lib.mkMerge [
    (lib.mkIf (p.random    != null) { terraform.required_providers.random    = mkReq p.random; })
    (lib.mkIf (p.tls       != null) { terraform.required_providers.tls       = mkReq p.tls; })
    (lib.mkIf (p.time      != null) { terraform.required_providers.time      = mkReq p.time; })
    (lib.mkIf (p.cloudinit != null) { terraform.required_providers.cloudinit = mkReq p.cloudinit; })
    (lib.mkIf (p.ansible   != null) { terraform.required_providers.ansible   = mkReq p.ansible; })
  ];
}
