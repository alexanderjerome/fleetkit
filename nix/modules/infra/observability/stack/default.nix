{ config, lib, pkgs, nodes ? { }, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.observability.stack;
  obs = config.fleet.settings.observability;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;

  # Grafana builder library (panels, dashboards, alerts)
  grafana = import ../../../../lib/grafana.nix { inherit lib; };

  # Reusable panel and alert definitions
  panels = import ./panels.nix { inherit grafana; };
  alerts = import ./alerts.nix { inherit grafana; };

  # ── Nix-defined alert groups (INFRA-106) ───────────────────────
  # The alerts.nix catalog + grafana.mkAlertRule was built but never wired in.
  # Activate it: build groups from the catalog, render to a provisioning file,
  # and merge with the hand-written YAML rules into one directory. Adding an
  # alert is now `(alerts.<name> { ... })` here — no raw YAML, auto-routes to
  # the slack-fleet contact point via the root policy.
  # Module-contributed alerts: each node appends to infra.observability.alerts.rules next to
  # its own service config; collect them fleet-wide here via Colmena `nodes`,
  # skipping hosts that set infra.observability.alerts.enable = false. Empty under a plain
  # nixosConfigurations eval (no `nodes`); populated on a Colmena deploy.
  fleetContributedRules = lib.concatMap
    (node: lib.optionals node.config.infra.observability.alerts.enable node.config.infra.observability.alerts.rules)
    (builtins.attrValues nodes);

  fleetNixAlertGroups =
    [
      (grafana.mkAlertGroup {
        name = "Fleet Health — Nix";
        rules = [
          (alerts.runawayTransaction { threshold = 3600; severity = "critical"; })
          (alerts.memoryPressure { threshold = 10; severity = "warning"; })
          # Fleet CPU saturation (INFRA-78). Hosts that legitimately run hot
          # (CPU miners, initial chain sync, batch workers) can be excluded
          # via fleet.settings.observability.cpuAlertExcludeRegex — with them
          # in, this rule would page permanently.
          (grafana.mkAlertRule {
            uid = "fleet-cpu-high";
            title = "High CPU (fleet)";
            expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",instance!~"${obs.cpuAlertExcludeRegex}"}[5m])))'';
            evaluator = { type = "gt"; params = [ 90 ]; };
            duration = "5m";
            annotations = {
              summary = "{{ $labels.instance }} CPU above 90% for 5m";
              description = "Sustained CPU saturation. Check `fleet remote {{ $labels.instance }} htop` for runaway processes; on PVE hosts also check per-CT load (`pct list` + host load).";
            };
            labels = { severity = "warning"; };
          })
          # pgbackrest safety net (INFRA-133): the guard that makes continuous
          # WAL archiving safe on analytics-db without an /etc/hosts pin — a
          # sustained archive-push failure or WAL pileup pages before /data
          # fills and postgres crash-loops (INFRA-91). Job-agnostic: covers
          # every postgres exporter publishing the metrics.
          (alerts.pgbackrestArchiveFailing { severity = "critical"; })
          (alerts.pgWalPileup { threshold = 15000000000; severity = "critical"; })
          # atticd = off-host Nix cache durability (push → Garage S3). Warning,
          # not critical: the fleet still builds/pulls via Harmonia when it is
          # down, but new build closures stop being backed up (INFRA-128).
          # NOT alerts.serviceDown: atticd exposes no /metrics endpoint (the
          # scrape 404s, so up{job="atticd"} could never be 1 and the alert
          # fired nonstop for 2 weeks — INFRA-146). Watch the systemd unit
          # state from node_exporter instead.
          (grafana.mkAlertRule {
            uid = "service-down-atticd";
            title = "atticd Down";
            expr = ''node_systemd_unit_state{name="atticd.service",state="active"}'';
            evaluator = { type = "lt"; params = [ 1 ]; };
            duration = "5m";
            noDataState = "Alerting";
            annotations = {
              summary = "atticd unit is not active on {{ $labels.instance }}";
              description = "The atticd.service systemd unit has not been active for 5m — new build closures are not being backed up to Garage S3. Check `journalctl -u atticd` on nix-builder.";
            };
            labels = { severity = "warning"; };
          })
          # Garage S3 fill — backs the atticd Nix cache, Loki chunks and
          # service uploads. Warn at 85%; critical at 90% (INFRA-247: the
          # warning tier alone sat unseen for 13 days while /data on the s3
          # host crossed 96%).
          (alerts.garageDiskFilling { threshold = 85; severity = "warning"; })
          (alerts.garageDiskFilling { threshold = 90; severity = "critical"; duration = "5m"; })
          # Archiving that stops making progress WITHOUT an error count
          # (INFRA-247) — the failure mode pgbackrestArchiveFailing cannot
          # see. 1h since the last shipped segment while postgres is up.
          (alerts.pgArchiveStalled { maxAge = 3600; severity = "critical"; })
        ];
      })
      # ── Fleet Health — generic host rules (INFRA-106, restored INFRA-247) ──
      # Disk %/absolute, failed systemd units, pg_up. Same group name and
      # rule uids as the retired fleet-health.yaml so the live provisioned
      # rules are adopted in place. Every fleet host with node_exporter /
      # the Alloy systemd collector is covered automatically.
      (grafana.mkAlertGroup {
        name = "Fleet Health";
        rules = [
          (alerts.diskLowPercent { threshold = 15; severity = "warning"; duration = "10m"; })
          (alerts.diskLowPercent { threshold = 7; severity = "critical"; duration = "5m"; })
          (alerts.diskFreeBytesFloor { })
          (alerts.unitFailed { })
          (alerts.postgresDown { })
        ];
      })
      # ── Hypervisor health (INFRA-167, follow-up to INFRA-164) ────
      # The layer below the fleet: PVE node liveness + lvmthin pool data%
      # from the reinstated pve-exporter (job=pve), plus the multi-TB
      # volume family on node_exporter metrics. The lvmthin thresholds
      # (85/92) page BEFORE a pool wedges every guest on it — the exact
      # class that took observability down for 2 days. The large-volume
      # rules intentionally overlap the generic fleet-disk %-rules on the
      # few multi-TB mounts (85 ≈ the 15%-free warning) but add a tighter
      # critical (92 vs 93) and the predict_linear runway signal the
      # "under 2 GiB free" floor cannot provide at 2 TB scale.
      (grafana.mkAlertGroup {
        name = "Hypervisor Health — Nix";
        rules = [
          (alerts.pveApiDown { })
          (alerts.pveNodeDown { })
          (alerts.pveStorageUsage { threshold = 85; severity = "warning"; duration = "15m"; })
          (alerts.pveStorageUsage { threshold = 92; severity = "critical"; duration = "5m"; })
          (alerts.largeVolumeUsage { threshold = 85; severity = "warning"; duration = "30m"; })
          (alerts.largeVolumeUsage { threshold = 92; severity = "critical"; duration = "10m"; })
          (alerts.largeVolumeFillPredicted { horizonDays = 14; })
        ];
      })
    ]
    ++ lib.optionals (fleetContributedRules != [ ]) [
      (grafana.mkAlertGroup {
        name = "Fleet — module-contributed";
        rules = fleetContributedRules;
      })
    ];
  # ── Notification routing (INFRA-247) ──────────────────────────
  # Severity tiers, each its own route so repeat cadence and receiver are
  # per-tier. Before this every alert — 13 days of critical disk / WAL /
  # pg-down included — went to ONE Slack channel at one 4h cadence and was
  # never seen. A Slack incoming webhook is bound to a single channel, so
  # a second channel means a second webhook: `criticalWebhookSecret`.
  #
  # Tree (Alertmanager semantics: first matching route wins, children
  # inherit receiver/group_by/repeat unless overridden):
  #
  #   root  → slack-fleet, group_by [alertname instance], repeat <default>
  #   ├── severity=critical → slack-alerts (or slack-fleet until the
  #   │                       webhook secret exists), repeat <critical>
  #   │     └── alertname in groupByAlertnameOnly → group_by [alertname]
  #   └── severity=warning  → slack-fleet, repeat <warning>
  #         └── alertname in groupByAlertnameOnly → group_by [alertname]
  #
  # Anything without a severity label (or with another value) falls to root.
  alerting = cfg.alerting;
  criticalSecret = alerting.slack.criticalWebhookSecret;

  # Eval-time preflight for the critical webhook: sops-nix does validate
  # declared keys, but only inside the manifest derivation at BUILD time,
  # with a log-buried error. We peek at the (plaintext-keyed, encrypted-
  # valued) default sops file for the key's last path segment instead, so
  # a missing secret degrades to a loud eval warning + criticals routed to
  # slack-fleet — the deploy still succeeds and the fix is one command
  # away. A false "present" (same-named key elsewhere in the file) is still
  # caught by sops-nix's build-time check.
  sopsFileHasKey = file: key:
    lib.any (l: lib.hasPrefix "${key}:" (lib.trim l))
      (lib.splitString "\n" (builtins.readFile file));
  criticalSecretAvailable = criticalSecret != null
    && sopsFileHasKey config.sops.defaultSopsFile (lib.last (lib.splitString "/" criticalSecret));
  criticalReceiver = if criticalSecretAvailable then "slack-alerts" else "slack-fleet";

  # Child route: named alerts group by alertname only, so a whole-host
  # outage is one post listing every failed unit, not one post per unit.
  alertnameOnlyRoutes = receiver:
    lib.optional (alerting.groupByAlertnameOnly != [ ]) {
      inherit receiver;
      object_matchers = [
        [ "alertname" "=~" "^(${lib.concatMapStringsSep "|" lib.escapeRegex alerting.groupByAlertnameOnly})$" ]
      ];
      group_by = [ "alertname" ];
    };
  severityRoute = { severity, receiver, repeatInterval }:
    let children = alertnameOnlyRoutes receiver;
    in {
      inherit receiver;
      object_matchers = [ [ "severity" "=" severity ] ];
      repeat_interval = repeatInterval;
    } // lib.optionalAttrs (children != [ ]) { routes = children; };

  nixAlertsProvisioning = pkgs.writeText "fleet-nix-alerts.yaml" (builtins.toJSON {
    apiVersion = 1;
    groups = fleetNixAlertGroups;
  });
  # JSON is valid YAML, so Grafana's *.yaml provisioning loader reads it fine.
  # Consumer-supplied rule directories (infra.observability.stack.alertRulesDirs)
  # are merged in front of the Nix-built catalog rules; on a filename clash
  # the later copy wins.
  alertRulesDir = pkgs.runCommand "grafana-alert-rules" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (dir: "cp ${dir}/*.yaml $out/") cfg.alertRulesDirs}
    cp ${nixAlertsProvisioning} $out/zz-fleet-nix-alerts.yaml
  '';

  # Fleet host inventory — sourced from the evaluated fleet module so the
  # dashboards can't drift from declared state.
  runtime = config.fleet.hostsJson;

  # Nix-defined dashboards organised into Grafana folders.
  # Each key under `nixDashboards` becomes a Grafana folder; the nested attrset
  # is { dashboard_filename_stem -> JSON string }. Only the generic Fleet
  # dashboards ship with the framework — consumer dashboards are injected as
  # pre-rendered JSON directories via infra.observability.stack.dashboardsDirs.
  nixDashboards = {
    "Fleet" = {
      "fleet-overview"       = import ./dashboards/fleet/fleet-overview.nix       { inherit lib grafana runtime; };
      "build-infrastructure" = import ./dashboards/fleet/build-infrastructure.nix { inherit grafana panels; };
      "hypervisors"          = import ./dashboards/fleet/hypervisors.nix          { inherit grafana panels; };
      "network-analytics"    = import ./dashboards/fleet/network-analytics.nix    { inherit grafana panels; };
    };
  };

  # Materialise each folder's dashboards into its own Nix store directory.
  # Grafana's file provider scans a single directory per provider, and the
  # provider's `folder` field is what determines the UI folder name.
  nixDashboardDirs = lib.mapAttrs (folderName: dashboards:
    pkgs.linkFarm "grafana-${lib.toLower (lib.replaceStrings [" "] ["-"] folderName)}-dashboards" (
      lib.mapAttrsToList (name: json: {
        name = "${name}.json";
        path = pkgs.writeText "${name}.json" json;
      }) dashboards
    )
  ) nixDashboards;
in
{
  options.infra.observability.stack = {
    enable = mkEnableOption "Self-hosted Grafana observability stack (Grafana + Loki + Prometheus)";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/observability";
      description = "Root directory for all observability data.";
    };

    grafana = {
      httpPort = mkOption {
        type = types.port;
        default = 3000;
        description = "Grafana HTTP listen port.";
      };
      domain = mkOption {
        type = types.nullOr types.str;
        default = obs.grafanaDomain;
        defaultText = lib.literalExpression "config.fleet.settings.observability.grafanaDomain";
        description = "Grafana server domain for URL generation. Must be non-null when infra.observability.stack is enabled (asserted).";
      };
    };

    dashboardsDirs = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = lib.literalExpression ''{ "My App" = ./dashboards/my-app; }'';
      description = ''
        Consumer-supplied dashboards: Grafana folder name → directory of
        pre-rendered dashboard JSON files. Each entry becomes its own file
        provider (same mechanism as the built-in Fleet folder) and shows up
        as a folder of that name in the Grafana UI.
      '';
    };

    alertRulesDirs = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = lib.literalExpression "[ ./alerts ]";
      description = ''
        Consumer-supplied directories of Grafana alert-rule provisioning
        YAML files (*.yaml). Merged with the framework's Nix-built alert
        catalog into the single provisioned alerting path.
      '';
    };

    alerting = {
      slack.criticalWebhookSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "services/grafana/slack_webhook_alerts";
        description = ''
          SOPS key (in `sops.defaultSopsFile`) holding a SECOND Slack incoming
          webhook, bound to the channel that must see `severity=critical`
          alerts. Provisions contact point `slack-alerts` and routes criticals
          to it; every other severity stays on `slack-fleet`
          (`services/grafana/slack_webhook`). A Slack webhook is bound to one
          channel, so two channels need two webhooks — create the second in
          Slack (App → Incoming Webhooks → Add to channel) and store it with
          `fleet devtools secrets keys add <this path> <webhook url>`.

          null keeps the single-channel setup. If the key is set but not yet
          present in the sops file, evaluation WARNS and criticals fall back
          to `slack-fleet` (so the deploy still succeeds); once the key exists
          the next deploy wires the second channel automatically.
        '';
      };
      repeatIntervals = {
        default = mkOption {
          type = types.str;
          default = "4h";
          description = "Root notification policy repeat_interval — alerts without a severity label (or with one no tier matches).";
        };
        critical = mkOption {
          type = types.str;
          default = "1h";
          description = "repeat_interval for the severity=critical route.";
        };
        warning = mkOption {
          type = types.str;
          default = "24h";
          description = "repeat_interval for the severity=warning route.";
        };
      };
      groupByAlertnameOnly = mkOption {
        type = types.listOf types.str;
        default = [ "Systemd Unit Failed" ];
        example = [ "Systemd Unit Failed" "Disk Low (warning)" ];
        description = ''
          Alert titles grouped by `alertname` only (the tree default is
          `[alertname instance]`): one Slack post per firing alert name across
          all hosts, so a single host outage that fails 25 units is one message
          listing them rather than 25 messages. Applied under both severity
          routes.
        '';
      };
    };

    extraDatasources = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      example = lib.literalExpression ''
        [ { name = "app-db"; type = "postgres"; url = "192.0.2.104:5432"; jsonData.sslmode = "disable"; } ]
      '';
      description = ''
        Extra Grafana datasources (verbatim provisioning attrsets) appended
        to the built-in Prometheus/Loki/Tempo ones — e.g. read-only
        PostgreSQL datasources for consumer dashboards. Secrets can be
        referenced with ''$__file{...} against SOPS-provisioned paths.
      '';
    };

    loki = {
      httpPort = mkOption {
        type = types.port;
        default = 3100;
        description = "Loki HTTP listen port.";
      };
      retentionPeriod = mkOption {
        type = types.str;
        # 90d (INFRA-169): chunks live in Garage S3 (2 TiB volume on the s3
        # host) as of the 2026-07-30 schema period, so retention is no longer
        # bounded by the grafana CT's 32G root disk on the pve-platform thin
        # pool (INFRA-164). The compactor enforces this across BOTH stores,
        # so pre-cutover filesystem chunks also age out under it.
        default = "90d";
        description = "How long to retain log data.";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication via Authentik";
      clientId = mkOption {
        type = types.str;
        default = "grafana";
        description = "OAuth2 client ID registered in Authentik.";
      };
    };

    prometheus = {
      httpPort = mkOption {
        type = types.port;
        default = 9090;
        description = "Prometheus HTTP listen port.";
      };
      retentionPeriod = mkOption {
        type = types.str;
        # 30d → 14d (INFRA-169): the 30d TSDB was one of the two growth
        # drivers that nearly filled the pve-platform thin pool (INFRA-164).
        # 14d covers every dashboard/alert window in use; long-horizon
        # trends belong in a remote store, not the local CT disk.
        default = "14d";
        description = "How long to retain metric data.";
      };
      scrapeInterval = mkOption {
        type = types.str;
        default = "15s";
        description = "Default scrape interval.";
      };
    };

    smtp = {
      enable = mkEnableOption "SMTP email via Resend for Grafana alert notifications";
      fromAddress = mkOption {
        type = types.nullOr types.str;
        default = if config.fleet.settings.domain.base != null
                  then "grafana@${config.fleet.settings.domain.base}" else null;
        defaultText = lib.literalExpression ''"grafana@''${config.fleet.settings.domain.base}"'';
        description = "Sender email address for Grafana alerts. Must be non-null when smtp.enable is set (asserted).";
      };
      fromName = mkOption {
        type = types.str;
        default = "Grafana";
        description = "Sender display name for Grafana alert emails.";
      };
    };
  };

  config = mkIf cfg.enable {
    sops.secrets."services/grafana/admin_password" = sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; };
    sops.secrets."services/grafana/secret_key" = sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; };
    sops.secrets."oidc/grafana/client_secret" = lib.mkIf cfg.oidc.enable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });
    sops.secrets."services/resend/smtp_secret" = lib.mkIf cfg.smtp.enable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });
    sops.secrets."services/resend/smtp_host" = lib.mkIf cfg.smtp.enable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });
    sops.secrets."services/resend/smtp_username" = lib.mkIf cfg.smtp.enable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });
    sops.secrets."services/resend/smtp_port" = lib.mkIf cfg.smtp.enable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });

    # Slack incoming-webhook for alert delivery (INFRA-106). File-mounted so the
    # provisioned contact point can load it via $__file{}. Born from the INFRA-91
    # disk-full outage: the alert rules existed but had nowhere to fire.
    sops.secrets."services/grafana/slack_webhook" = sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; };

    # Second webhook → the critical-alerts channel (INFRA-247). Declared only
    # once the key is really in the sops file; see criticalSecretAvailable.
    # (A null dynamic attribute name is dropped by Nix, so this is a no-op
    # when the option is unset.)
    sops.secrets.${criticalSecret} = lib.mkIf criticalSecretAvailable (sopsLib.mkSecret {
      restartUnits = [ "grafana.service" ];
    } // { owner = "grafana"; });

    warnings = lib.optional (criticalSecret != null && !criticalSecretAvailable) ''
      infra.observability.stack.alerting.slack.criticalWebhookSecret = "${criticalSecret}"
      but no `${lib.last (lib.splitString "/" criticalSecret)}:` key was found in
      ${toString config.sops.defaultSopsFile}. Critical alerts are being routed
      to the slack-fleet contact point until it exists. Create a Slack incoming
      webhook for the critical channel, then run:
        fleet devtools secrets keys add ${criticalSecret} '<webhook url>'
      and redeploy the grafana host.
    '';

    services.grafana = {
      enable = true;
      settings.server = {
        http_addr = "0.0.0.0";  # allow access from MCP gateway on devops
        http_port = cfg.grafana.httpPort;
        domain = cfg.grafana.domain;
        root_url = "https://${cfg.grafana.domain}";
      };
      settings.security = {
        admin_password = "$__file{${config.sops.secrets."services/grafana/admin_password".path}}";
        secret_key = "$__file{${config.sops.secrets."services/grafana/secret_key".path}}";
      };
      settings.smtp = lib.mkIf cfg.smtp.enable {
        enabled = true;
        host = "$__file{${config.sops.secrets."services/resend/smtp_host".path}}:$__file{${config.sops.secrets."services/resend/smtp_port".path}}";
        user = "$__file{${config.sops.secrets."services/resend/smtp_username".path}}";
        password = "$__file{${config.sops.secrets."services/resend/smtp_secret".path}}";
        from_address = cfg.smtp.fromAddress;
        from_name = cfg.smtp.fromName;
      };
      settings."auth.generic_oauth" = lib.mkIf cfg.oidc.enable {
        enabled = true;
        name = "Authentik";
        client_id = cfg.oidc.clientId;
        client_secret = "$__file{${config.sops.secrets."oidc/grafana/client_secret".path}}";
        scopes = "openid email profile groups";
        auth_url = "${config.fleet.settings.auth.oidcBaseUrl}/application/o/authorize/";
        token_url = "${config.fleet.settings.auth.oidcBaseUrl}/application/o/token/";
        api_url = "${config.fleet.settings.auth.oidcBaseUrl}/application/o/userinfo/";
        role_attribute_path = "contains(groups[*], 'platform-admins') && 'Admin' || contains(groups[*], 'developers') && 'Editor' || 'Viewer'";
        allow_assign_grafana_admin = true;
      };
      provision.datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          url = "http://localhost:${toString cfg.prometheus.httpPort}";
          isDefault = true;
        }
        {
          name = "Loki";
          type = "loki";
          uid = "loki";
          url = "http://localhost:${toString cfg.loki.httpPort}";
        }
      ]
      # Tempo trace store, when the fleet runs one (INFRA-47 / ADR-038).
      # tracesToLogsV2 lets a span jump straight to its Loki logs by trace id.
      ++ lib.optional (obs.tempoUrl != null) {
        name = "Tempo";
        type = "tempo";
        uid = "tempo";
        url = obs.tempoUrl;
        jsonData = {
          tracesToLogsV2 = {
            datasourceUid = "loki";
            spanStartTimeShift = "-1h";
            spanEndTimeShift = "1h";
            filterByTraceID = true;
          };
        };
      }
      # Consumer-supplied datasources (e.g. read-only app DBs for injected
      # dashboards) — provisioned verbatim.
      ++ cfg.extraDatasources;

      # Provisioned dashboards: one provider per Grafana folder.
      # allowUiUpdates=false means UI edits cannot overwrite the provisioned source.
      # Combined with editable=false in the dashboard JSON, users see a read-only
      # banner and must edit the .nix file to make persistent changes.
      provision.dashboards.settings.providers = lib.mapAttrsToList (folderName: path: {
        name = "fleet — ${folderName}";
        folder = folderName;
        allowUiUpdates = false;
        options.path = path;
        options.foldersFromFilesStructure = false;
      }) (nixDashboardDirs // cfg.dashboardsDirs);

      # Provisioned alert rules — hand-written YAML + Nix-built catalog rules,
      # merged into one dir (see alertRulesDir above).
      provision.alerting.rules.path = alertRulesDir;

      # Slack contact points — webhooks loaded from SOPS via $__file{}.
      #   slack-fleet  (INFRA-106): the everything channel — warnings + root.
      #   slack-alerts (INFRA-247): severity=critical, only when its webhook
      #                secret exists (see alerting.slack.criticalWebhookSecret).
      provision.alerting.contactPoints.settings = {
        apiVersion = 1;
        contactPoints = [
          {
            orgId = 1;
            name = "slack-fleet";
            receivers = [{
              uid = "slack_fleet_webhook";
              type = "slack";
              disableResolveMessage = false;
              settings.url = "$__file{${config.sops.secrets."services/grafana/slack_webhook".path}}";
            }];
          }
        ] ++ lib.optional criticalSecretAvailable {
          orgId = 1;
          name = "slack-alerts";
          receivers = [{
            uid = "slack_alerts_webhook";
            type = "slack";
            disableResolveMessage = false;
            settings.url = "$__file{${config.sops.secrets.${criticalSecret}.path}}";
          }];
        };
      };

      # Notification policy tree — see the routing comment above
      # `alerting = cfg.alerting`. Root catches everything (the whole point:
      # disk/unit-failed/postgres-down must page, not just sit in the UI);
      # severity routes set the receiver + repeat cadence per tier.
      # Grafana's embedded Alertmanager has NO inhibition rules and its mute
      # timings are calendar-only, so cross-alert suppression (PostgreSQL
      # Down silencing the same host's failed units) lives in the PromQL of
      # alerts.unitFailed instead.
      provision.alerting.policies.settings = {
        apiVersion = 1;
        policies = [{
          orgId = 1;
          receiver = "slack-fleet";
          group_by = [ "alertname" "instance" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = alerting.repeatIntervals.default;
          routes = [
            (severityRoute {
              severity = "critical";
              receiver = criticalReceiver;
              repeatInterval = alerting.repeatIntervals.critical;
            })
            (severityRoute {
              severity = "warning";
              receiver = "slack-fleet";
              repeatInterval = alerting.repeatIntervals.warning;
            })
          ];
        }];
      };
    };

    # ── Loki chunk store → in-fleet S3 (INFRA-169) ───────────────
    # Chunk growth on the grafana CT's root disk was one of the two
    # drivers that nearly filled a hypervisor thin pool (INFRA-164).
    # Chunks + index now ship to the in-fleet S3 (Garage,
    # fleet.settings.observability.lokiS3Endpoint) — same
    # endpoint/credential pattern as atticd and pgbackrest.
    # Credentials arrive as standard AWS_* env
    # vars from a SOPS template; Loki's S3 client falls back to the AWS
    # default credential chain when no static keys are in storage_config,
    # so nothing secret lands in the world-readable config file.
    #
    # One-time Garage provisioning (live actions — run BEFORE deploying
    # this to the grafana host, in this order):
    #   1. Bucket — declared in infra.data.s3.buckets on the s3
    #      host; `fleet deploy nixos apply host s3` creates it. (Manual
    #      equivalent on the s3 host: `garage bucket create loki-chunks`.)
    #   2. Key — `fleet s3 mint-key loki-chunks-key loki-chunks \
    #               --sops-prefix services/loki/garage`
    #      mints the key, grants --read --write on the bucket, and saves
    #      services/loki/garage/{access_key_id,secret_access_key,...} to
    #      SOPS. (Manual equivalent: `garage key create loki-chunks-key`
    #      + `garage bucket allow loki-chunks --read --write --key
    #      loki-chunks-key`, then add the two SOPS keys by hand.)
    sops.secrets."services/loki/garage/access_key_id" = sopsLib.mkSecret {
      restartUnits = [ "loki.service" ];
    };
    sops.secrets."services/loki/garage/secret_access_key" = sopsLib.mkSecret {
      restartUnits = [ "loki.service" ];
    };
    sops.templates."loki-garage-env" = sopsLib.mkTemplate {
      content = ''
        AWS_ACCESS_KEY_ID=${p."services/loki/garage/access_key_id"}
        AWS_SECRET_ACCESS_KEY=${p."services/loki/garage/secret_access_key"}
      '';
    };
    systemd.services.loki.serviceConfig.EnvironmentFile =
      config.sops.templates."loki-garage-env".path;

    services.loki = {
      enable = true;
      dataDir = "${cfg.dataDir}/loki";
      configuration = {
        auth_enabled = false;
        server.http_listen_port = cfg.loki.httpPort;
        common = {
          ring.kvstore.store = "inmemory";
          replication_factor = 1;
          path_prefix = "${cfg.dataDir}/loki";
        };
        schema_config.configs = [
          # Original local-filesystem period — NEVER modify or remove a
          # live period: chunks/index already written are addressed by
          # this exact config. It keeps serving pre-cutover data until
          # retention ages it out, then the local store sits empty.
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = { prefix = "index_"; period = "24h"; };
          }
          # INFRA-169: chunk cutover to Garage S3. Same schema version +
          # index layout — ONLY the object store changes. The `from` date
          # must still be in the future (UTC) when this lands on the host;
          # if deploying on/after 2026-07-30, bump it to tomorrow first.
          {
            from = "2026-07-30";
            store = "tsdb";
            object_store = "s3";
            schema = "v13";
            index = { prefix = "index_"; period = "24h"; };
          }
        ];
        storage_config = {
          # Old-period chunk store (pre-2026-07-30 data) — ages out under
          # retention_period, no new writes after the cutover.
          filesystem.directory = "${cfg.dataDir}/loki/chunks";
          # Garage S3 (INFRA-169). HTTP-direct like atticd —
          # fleet-internal traffic on a trusted L2 skips the Caddy TLS
          # hop. Path-style addressing (Garage default, same as
          # pgbackrest's repo1-s3-uri-style=path); region is a label
          # Garage ignores but the SDK requires.
          aws = {
            endpoint = obs.lokiS3Endpoint;
            region = "us-east-1";
            bucketnames = "loki-chunks";
            s3forcepathstyle = true;
            # No static keys here — credentials come from the AWS_* env
            # vars in sops.templates."loki-garage-env" above.
          };
        };
        limits_config.retention_period = cfg.loki.retentionPeriod;
        compactor = {
          working_directory = "${cfg.dataDir}/loki/compactor";
          retention_enabled = true;
          # Retention bookkeeping moves to S3 with the chunks (INFRA-169)
          # so compactor state survives the local disk. Pre-cutover delete
          # requests on the filesystem store are abandoned (none pending).
          delete_request_store = "s3";
        };
      };
    };

    services.prometheus = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = cfg.prometheus.httpPort;
      retentionTime = cfg.prometheus.retentionPeriod;
      globalConfig.scrape_interval = cfg.prometheus.scrapeInterval;
      extraFlags = [ "--web.enable-remote-write-receiver" ];
      scrapeConfigs = [{
        job_name = "prometheus";
        static_configs = [{ targets = [ "localhost:${toString cfg.prometheus.httpPort}" ]; }];
      }];
    };

    # ── Proxmox VE exporter — hypervisor liveness + lvmthin storage (INFRA-167) ──
    # Reinstated after INFRA-128 removed the original (its root@pam token was
    # broken and produced zero series). The OTLP datacenter metric server
    # (job=proxmox-ve, proxmox_*, nix/hosts/pve/otel.nix) is PUSH-based: when a
    # node wedges — the INFRA-164 thin-pool-100% class — its series just stop,
    # with no `up` to alert on. This exporter is PULLED per node, so
    # up{job="pve",instance="pve-<name>"} is a real liveness signal, and
    # pve_disk_usage_bytes/pve_disk_size_bytes on lvmthin storages is the thin
    # pool DATA usage that hit 100% in that incident.
    # Auth: dedicated least-privilege token pve-exporter@pve!exporter
    # (PVEAuditor on /, privsep=0), created once on any cluster node — the
    # pve realm is cluster-wide.
    services.prometheus.exporters.pve = {
      enable = true;
      port = 9221;
      configFile = config.sops.templates."pve-exporter-config".path;
    };

    sops.templates."pve-exporter-config" = sopsLib.mkTemplate {
      restartUnits = [ "prometheus-pve-exporter.service" ];
      content = ''
        default:
          user: pve-exporter@pve
          token_name: exporter
          token_value: ${p."services/grafana/pve_exporter_token"}
          verify_ssl: false
      '';
    };
    sops.secrets."services/grafana/pve_exporter_token" = sopsLib.mkSecret {
      restartUnits = [ "prometheus-pve-exporter.service" ];
    };

    # ── XO exporter — XCP-ng tier-0 metrics via the XOA REST API (INFRA-40) ──
    # Our XOA edition ships no OpenMetrics plugin and we hold no dom0
    # credentials, so nix/pkgs/xo-grafana-exporter polls XO REST live at
    # scrape time. Credentials arrive via systemd LoadCredential because
    # a DynamicUser cannot read root-owned sops paths directly.
    systemd.services.xo-grafana-exporter = {
      description = "Prometheus exporter for XCP-ng via Xen Orchestra REST";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        XO_EXPORTER_ADDR = "127.0.0.1";
        XO_EXPORTER_PORT = "9603";
      };
      # The URL credential must land in an env var the exporter reads, and
      # ExecStart $VAR substitution is unreliable on this fleet for
      # env-sourced vars — hence a script wrapper instead of ExecStart.
      script = ''
        export XOA_URL="$(cat "$CREDENTIALS_DIRECTORY/url")"
        export XOA_TOKEN_FILE="$CREDENTIALS_DIRECTORY/token"
        exec ${pkgs.callPackage ../../../../pkgs/xo-grafana-exporter { }}/bin/xo-grafana-exporter
      '';
      serviceConfig = {
        DynamicUser = true;
        LoadCredential = [
          "url:${config.sops.secrets."integrations/xen-orchestra/url".path}"
          "token:${config.sops.secrets."integrations/xen-orchestra/token".path}"
        ];
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    sops.secrets."integrations/xen-orchestra/url" = sopsLib.mkSecret {
      restartUnits = [ "xo-grafana-exporter.service" ];
    };
    sops.secrets."integrations/xen-orchestra/token" = sopsLib.mkSecret {
      restartUnits = [ "xo-grafana-exporter.service" ];
    };

    assertions = [
      {
        assertion = !cfg.oidc.enable || config.fleet.settings.auth.oidcBaseUrl != null;
        message = "infra.observability.stack.oidc.enable requires fleet.settings.auth.oidcBaseUrl to be set.";
      }
      {
        assertion = cfg.grafana.domain != null;
        message = "infra.observability.stack.enable is set but infra.observability.stack.grafana.domain is null — set fleet.settings.observability.grafanaDomain (or infra.observability.stack.grafana.domain).";
      }
      {
        assertion = obs.lokiS3Endpoint != null;
        message = "infra.observability.stack.enable is set but fleet.settings.observability.lokiS3Endpoint is null — Loki needs an S3-compatible chunk store endpoint.";
      }
      {
        assertion = !cfg.smtp.enable || cfg.smtp.fromAddress != null;
        message = "infra.observability.stack.smtp.enable is set but infra.observability.stack.smtp.fromAddress is null — set fleet.settings.domain.base (or smtp.fromAddress explicitly).";
      }
    ];

    # Alloy scrape for PVE + XO metrics
    infra.observability.alloy.extraConfig = lib.mkAfter ''

      // ── Proxmox VE hypervisor metrics via pve-exporter (INFRA-167) ──
      // Multi-target: ONE local exporter instance, one scrape target per
      // cluster node (?target=<node ip> on /pve), from
      // fleet.settings.observability.pveScrapeTargets. Every target answers
      // with the cluster-wide /cluster/resources series, so alert exprs
      // dedupe with max by (...); what the per-node fan-out buys is a
      // per-hypervisor up{} liveness signal and survival of any single
      // node's API being down. 60s interval: keep the load light.
      prometheus.scrape "pve" {
        targets = [
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList
            (name: addr: ''{"__address__" = "127.0.0.1:9221", "__param_target" = "${addr}", "instance" = "${name}"},'')
            obs.pveScrapeTargets)}
        ]
        params = {
          module = ["default"],
          cluster = ["1"],
          node = ["1"],
        }
        metrics_path = "/pve"
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "60s"
        job_name = "pve"
      }

      // ── XCP-ng tier-0 metrics via XO REST (INFRA-40) ──
      prometheus.scrape "xo" {
        targets = [
          {"__address__" = "127.0.0.1:9603"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        job_name = "xo"
      }

      // ── XCP-ng dom0 syslog → Loki (INFRA-40) ──
      // The XCP-ng host forwards its syslog here, configured tier-0-side
      // via `xo-cli host.setRemoteSyslogHost` (XAPI rewrites dom0's
      // rsyslog config; destination port is fixed at 514/udp, RFC3164).
      loki.source.syslog "xcpng" {
        listener {
          address       = "0.0.0.0:514"
          protocol      = "udp"
          syslog_format = "rfc3164"
          labels        = { job = "xcpng-syslog", tier = "substrate" }
        }
        forward_to = [loki.write.default.receiver]
      }
    '';

    # Syslog receiver: 514/udp is privileged and dom0's rsyslog can't be
    # pointed anywhere else — grant alloy the bind capability and open
    # the firewall for the substrate network.
    systemd.services.alloy.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    networking.firewall.allowedUDPPorts = [ 514 ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/loki 0755 loki loki -"
      "d ${cfg.dataDir}/loki/chunks 0755 loki loki -"
      "d ${cfg.dataDir}/loki/compactor 0755 loki loki -"
      # INFRA-188: retention marker files are transient delete-bookkeeping —
      # the compactor writes them, processes them within retention_delete_delay
      # (hours), and removes them. Anything older is crash debris; corrupted
      # markers (boltdb "invalid database") are skipped forever, spamming warns
      # and leaking the chunks they reference. Age them out daily via
      # systemd-tmpfiles-clean so a crash can't wedge retention permanently.
      "e ${cfg.dataDir}/loki/compactor/retention/*/markers 0755 loki loki 7d"
    ];

    infra.services.grafana = {
      port = cfg.grafana.httpPort;
      description = "Grafana dashboards and observability UI";
      category = "observability";
      tags = [ "web-ui" ];
    };
    infra.services.loki = {
      port = cfg.loki.httpPort;
      caddy.enable = false;
      description = "Loki log aggregation push endpoint";
      category = "observability";
      tags = [ "internal" ];
    };
    infra.services.prometheus = {
      port = cfg.prometheus.httpPort;
      caddy.enable = false;
      description = "Prometheus metrics and remote-write receiver";
      category = "observability";
      tags = [ "internal" ];
    };
  };
}
