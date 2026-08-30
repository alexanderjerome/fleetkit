{ lib }:

# Constructors for Grafana Cloud synthetic monitoring checks (INFRA-144).
#
# A check is a plain `fleet.resources` entry (kind = "sm-check") that the
# emitter in nix/tf/resources/grafana.nix turns into a
# `grafana_synthetic_monitoring_check`. All checks land in the
# `platform.grafana-cloud` leaf stack regardless of where they are
# declared, so a HOST FILE can attach a check for its public domain right
# next to its fleet.compute entry:
#
#   { lib, ... }:
#   let grafanaLib = import ../../lib/tf/grafana.nix { inherit lib; };
#   in {
#     config.fleet.compute.authentik = { ... };
#     config.fleet.resources.sm-check-auth = grafanaLib.mkHttpCheck {
#       job = "Authentik SSO";
#       target = "https://auth.example.dev";
#     };
#   }
#
# Apply with: fleet deploy tf apply platform.grafana-cloud --yes
#
# `probes` are Grafana Cloud PUBLIC probe location NAMES (Montreal,
# NorthVirginia, Ohio, Frankfurt, …) — resolved to IDs at plan time via
# `data.grafana_synthetic_monitoring_probes`. Alerting on failures is the
# SM app's built-in ProbeFailedExecutionsTooHigh rule, gated per-check by
# `alertSensitivity` ("none" disables alerting for that check).

let
  common = {
    env = "platform";
    stack = "grafana-cloud";
    provider_instance = "grafana.cloud";
    kind = "sm-check";
  };

  # Two US-East-ish probes by default: redundancy without burning
  # execution quota. Override per-check for geo-sensitive targets.
  defaultProbes = [ "Montreal" "NorthVirginia" ];
in
rec {
  # HTTP(S) GET check. `target` must be a full URL.
  #   httpSettings — extra keys merged into settings.http (snake_case,
  #   grafana_synthetic_monitoring_check schema), e.g.
  #   { valid_status_codes = [ 200 404 ]; fail_if_body_not_matches_regexp = [ "ok" ]; }
  mkHttpCheck =
    { job
    , target
    , probes ? defaultProbes
    , frequencySeconds ? 300
    , timeoutSeconds ? 5
    , alertSensitivity ? "high"
    , enabled ? true
    , labels ? {}
    , httpSettings ? {}
    , notes ? ""
    }: common // {
      inherit job target probes enabled labels notes;
      check_type = "http";
      frequency_seconds = frequencySeconds;
      timeout_seconds = timeoutSeconds;
      alert_sensitivity = alertSensitivity;
      http_settings = {
        ip_version = "V4";
        method = "GET";
        # Public surfaces must present valid TLS — fail the check on
        # plain HTTP (mirrors what a browser user would experience).
        fail_if_not_ssl = true;
        valid_status_codes = [ 200 ];
      } // httpSettings;
    };

  # TCP connect check. `target` must be "<host>:<port>".
  mkTcpCheck =
    { job
    , target
    , probes ? defaultProbes
    , frequencySeconds ? 300
    , timeoutSeconds ? 5
    , alertSensitivity ? "high"
    , enabled ? true
    , labels ? {}
    , tcpSettings ? {}
    , notes ? ""
    }: common // {
      inherit job target probes enabled labels notes;
      check_type = "tcp";
      frequency_seconds = frequencySeconds;
      timeout_seconds = timeoutSeconds;
      alert_sensitivity = alertSensitivity;
      tcp_settings = { ip_version = "V4"; } // tcpSettings;
    };
}
