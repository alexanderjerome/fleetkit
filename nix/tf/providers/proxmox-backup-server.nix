{ config, lib, ... }:

# Tinyblargon/proxmox-backup-server provider config — one `provider
# "proxmox-backup-server"` block per instance in
# fleet.providers.proxmox-backup-server. Aliased so PBS-side resources
# bind via `provider = "proxmox-backup-server.<instance>"`.
#
# Provider schema (Tinyblargon/proxmox-backup-server):
#   * endpoint      — https://<host>:8007
#   * api_token     — full token string "<USER>@<REALM>!<TOKEN>=<UUID>"
#                     (or alternatively username + password)
#   * insecure      — skip TLS verify (we use the internal step-ca cert)
#
# Token minted + saved by `fleet pbs issue-tf-token`. Path:
# integrations/pbs/<instance>/api_token.

let
  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };

  mkProviderBlock = instance: cfg: {
    alias = instance;
    endpoint = cfg.endpoint;
    api_token = sopsLib.sopsRef cfg.secrets.api_token;
    insecure = cfg.insecure;
  };
in {
  # Only emit if at least one PBS instance is declared.
  config = lib.mkIf (config.fleet.providers.proxmox-backup-server != {}) {
    terraform.required_providers.proxmox-backup-server = {
      source = "Tinyblargon/proxmox-backup-server";
      version =
        let versions = lib.mapAttrsToList (_: c: c.version)
          config.fleet.providers.proxmox-backup-server;
        in lib.head versions;
    };

    provider.proxmox-backup-server =
      lib.mapAttrsToList mkProviderBlock
        config.fleet.providers.proxmox-backup-server;
  };
}
