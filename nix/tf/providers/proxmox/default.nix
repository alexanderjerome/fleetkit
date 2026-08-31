{ config, lib, ... }:

# bpg/proxmox provider config — one `provider "proxmox"` block per
# instance in fleet.providers.proxmox, aliased so resources can bind
# via `provider = "proxmox.<instance>"`.

let
  sopsLib = import ../../../lib/tf/sops.nix { inherit lib; };

  # Two auth shapes supported, decided by which keys the instance's
  # `secrets` map carries:
  #   * `api_token` (single string of form "<USER>@<REALM>!<TOKEN>=<UUID>")
  #     — minted via `fleet pve cluster issue-tf-token`. Preferred for new
  #     instances (scoped + revocable in the PVE UI).
  #   * `username` + `password` — legacy pair, still used by the OLD
  #     proxmox.dev instance until it's retired.
  mkProviderBlock = instance: cfg:
    let
      hasApiToken = cfg.secrets ? api_token;
      base = {
        alias = instance;
        endpoint = cfg.endpoint;
        insecure = cfg.insecure;
        ssh = { agent = true; username = "root"; };
      };
    in base // (
      if hasApiToken
      then { api_token = sopsLib.sopsRef cfg.secrets.api_token; }
      else {
        username = sopsLib.sopsRef cfg.secrets.username;
        password = sopsLib.sopsRef cfg.secrets.password;
      }
    );
in {
  # Only emit if there's at least one proxmox instance.
  config = lib.mkIf (config.fleet.providers.proxmox != {}) {
    terraform.required_providers.proxmox = {
      source = "bpg/proxmox";
      # Pin the lowest common version across all instances.
      version =
        let versions = lib.mapAttrsToList (_: c: c.version)
          config.fleet.providers.proxmox;
        in lib.head versions;
    };

    # List form — terraform supports multiple provider blocks for the
    # same provider by aliasing. terranix serialises provider-as-list
    # into the right JSON shape.
    provider.proxmox = lib.mapAttrsToList mkProviderBlock
      config.fleet.providers.proxmox;
  };
}
