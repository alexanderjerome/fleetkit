{ ... }:

# Provider instances (schema: fleetkit nix/fleet/providers/default.nix).
# Credentials are SOPS paths into your nix/secrets/secrets.yaml — never
# literals here.

{
  config.fleet.providers = {
    proxmox.main = {
      source = "bpg/proxmox";
      version = "~> 0.103";
      endpoint = "https://192.0.2.2:8006";
      secrets = {
        api_token = "integrations/proxmox/main/api_token";
      };
      insecure = true;
      state.prefix = "tf/proxmox-main";
      cluster = {
        nodes = [ "pve1" ];
        primary_node = "pve1";
        ha_manager = false;
      };
      destruction_policy = "standard";
    };
  };
}
