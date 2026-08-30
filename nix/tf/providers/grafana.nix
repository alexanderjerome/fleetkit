{ config, lib, ... }:

# grafana/grafana provider config (INFRA-144) — single instance
# (`grafana.cloud`, the techa96b Grafana Cloud stack). Two auth surfaces:
#   auth            — stack service-account token → instance APIs
#                     (alerting contact points, templates, dashboards).
#   sm_access_token — Synthetic Monitoring tenant token → SM API
#                     (checks, probes).

let
  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };
  instances = config.fleet.providers.grafana;
  inst = lib.head (lib.attrValues instances);
in {
  config = lib.mkIf (instances != {}) {
    terraform.required_providers.grafana = {
      source = inst.source;
      version = inst.version;
    };

    provider.grafana = {
      url = inst.endpoint;
      auth = sopsLib.sopsRef inst.secrets.auth;
      # Region-fixed SM API endpoint for us-east stacks. Read from the SM
      # datasource's jsonData.apiHost on the stack; changes only if the
      # stack migrates regions.
      sm_url = "https://synthetic-monitoring-api-us-east-0.grafana.net";
      sm_access_token = sopsLib.sopsRef inst.secrets.sm_access_token;
    };
  };
}
