{ config, lib, pkgs, ... }:

# infra.sssdProbe — scheduled end-to-end directory-auth probe (INFRA-200).
#
# The INFRA-190 outage class (LDAP outpost/provider silently broken, SSSD
# offline fleet-wide) ran for weeks because nothing exercised the login
# path. This module runs `fleet devtools sssd-test` continuously: a timer on
# the prober host SSHes to each target as the `sssd-probe` service user
# using the SOPS-held key, so a green probe proves the whole chain —
# Authentik user store → LDAP outpost → SSSD (NSS + LDAP-served key) →
# sshd — on that target. Results land as textfile metrics
# (sssd_probe_success{target=...}) via alloy's node exporter, with a
# contributed alert that also pages when the metric goes ABSENT (a dead
# prober must not look like health).
let
  inherit (lib) mkEnableOption mkOption mkIf types concatStringsSep mapAttrsToList;
  cfg = config.infra.sssdProbe;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  grafana = import ../../../../lib/grafana.nix { inherit lib; };
in
{
  options.infra.sssdProbe = {
    enable = mkEnableOption "scheduled fleet directory-auth probe (INFRA-200)";

    targets = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { dash = "192.0.2.20"; };
      description = ''
        Hosts to probe: metric target name → IP. Only add hosts that carry
        the INFRA-190 sssd config (ldap-bind + wrapper integration) — a
        not-yet-converged host fails by design, which is signal during a
        rollout but noise as a steady state.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "15min";
      description = "Probe cadence (systemd OnUnitActiveSec).";
    };
  };

  config = mkIf cfg.enable {
    sops.secrets."services/sssd-test/ssh_private_key" = sopsLib.mkSecret {
      restartUnits = [ ];
    };

    systemd.tmpfiles.rules = [ "d /var/lib/sssd-probe 0700 root root -" ];

    systemd.services.sssd-probe = {
      description = "Fleet directory-auth probe (INFRA-200)";
      serviceConfig = { Type = "oneshot"; };
      path = [ pkgs.openssh pkgs.coreutils ];
      script = ''
        out=/var/lib/alloy-textfile/sssd_probe.prom
        tmp="$out.tmp"
        : > "$tmp"
        echo "# HELP sssd_probe_success 1 when an LDAP-keyed SSH login as sssd-probe succeeds on the target" >> "$tmp"
        echo "# TYPE sssd_probe_success gauge" >> "$tmp"
        ${concatStringsSep "\n" (mapAttrsToList (name: ip: ''
          if timeout 40 ssh \
              -i ${config.sops.secrets."services/sssd-test/ssh_private_key".path} \
              -o BatchMode=yes -o IdentitiesOnly=yes \
              -o StrictHostKeyChecking=accept-new \
              -o UserKnownHostsFile=/var/lib/sssd-probe/known_hosts \
              -o ConnectTimeout=10 \
              sssd-probe@${ip} true; then
            echo 'sssd_probe_success{target="${name}"} 1' >> "$tmp"
          else
            echo 'sssd_probe_success{target="${name}"} 0' >> "$tmp"
          fi
        '') cfg.targets)}
        mv "$tmp" "$out"
      '';
    };

    systemd.timers.sssd-probe = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.interval;
      };
    };

    # Module-contributed alert (INFRA-106 pattern). noDataState=Alerting on
    # purpose: if the prober dies or the textfile stops flowing, silence
    # must page — that is exactly how the INFRA-190 outage stayed hidden.
    infra.alerts.rules = [
      (grafana.mkAlertRule {
        uid = "sssd-probe-failing";
        title = "Directory auth probe failing";
        expr = ''min by (target) (sssd_probe_success)'';
        evaluator = { type = "lt"; params = [ 1 ]; };
        duration = "30m";
        noDataState = "Alerting";
        annotations = {
          summary = "Directory-auth probe failing for {{ $labels.target }}";
          description = "fleet devtools sssd-test {{ $labels.target }} reproduces it interactively. Chain: identity provider up → LDAP outpost serving → sssd online on the target (sssctl domain-status <domain>) → getent passwd sssd-probe. See INFRA-190 for the full failure taxonomy.";
        };
        labels = { severity = "warning"; };
      })
    ];
  };
}
