# infra.alerts — fleet alert aggregation (INFRA-106).
#
# Service modules contribute Grafana alert rules close to their own config via
# `infra.alerts.rules`. Each host therefore carries the alert rules for the
# modules it actually runs. The central grafana host collects every node's
# contributions (via Colmena `nodes`) and provisions them — so an alert lives
# next to the service that owns it, yet is delivered from one place.
#
# Per-host opt-out: set `infra.alerts.enable = false` on a host to drop ALL of
# its contributed alerts from the fleet (e.g. signet, which mirrors mainnet's
# modules but isn't worth paging on). Modules may also expose their own
# `alerts.enable` sub-toggle for finer control. Default: enabled everywhere.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.infra.alerts = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether this host contributes its alert rules to the fleet. When false,
        none of this host's `infra.alerts.rules` are collected/provisioned by the
        grafana host. Use to opt a host out of alerting entirely (e.g. signet).
      '';
    };

    rules = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      example = lib.literalExpression ''
        [ (grafana.mkAlertRule {
            uid = "svc-down";
            title = "Service down";
            expr = "up{job=\"myservice\"} == 0";
            for = "5m";
          }) ]
      '';
      description = ''
        Grafana alert-rule attrsets (built via `grafana.mkAlertRule`) contributed
        by the modules enabled on this host. Mergeable — every module that wants
        an alert appends to it. Consumed centrally by the grafana-stack module,
        which gathers this across all nodes with `infra.alerts.enable = true`.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "Fleet — module-contributed";
      description = "Grafana alert group name these contributed rules land in.";
    };
  };

  # No host-local config: this option only carries data consumed by grafana.
}
