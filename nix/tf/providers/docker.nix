{ config, lib, ... }:

# kreuzwerker/docker provider config — one aliased `provider "docker"`
# block per instance in fleet.providers.docker, so resources bind via
# `provider = "docker.<instance>"`.
#
# Each instance's `endpoint` is the daemon URL. ssh:// tunnels the
# docker socket over an existing SSH path (matches how the proxmox
# provider already reaches hosts: ssh.agent = true, root). TLS material,
# if a tcp:// daemon needs it, comes from SOPS via `secrets`.
#
# Emits nothing when no instance is declared — keeps `tofu init` from
# pulling the provider into stacks that don't use docker.

let
  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };
  instances = config.fleet.providers.docker;

  mkBlock = name: cfg:
    { alias = name; host = cfg.endpoint; }
    # Map any SOPS-backed secrets straight onto the provider block
    # (e.g. ca_material / cert_material / key_material for a tcp+tls
    # daemon). No-op for the common ssh:// case.
    // (lib.mapAttrs (_: path: sopsLib.sopsRef path) cfg.secrets);
in {
  config = lib.mkIf (instances != {}) {
    terraform.required_providers.docker = {
      source = "kreuzwerker/docker";
      version = lib.head (lib.mapAttrsToList (_: c: c.version) instances);
    };

    provider.docker = lib.mapAttrsToList mkBlock instances;
  };
}
