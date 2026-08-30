{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types optionalString;
  cfg = config.infra.observability.alloy;
  dockerEnabled = config.infra.integrations.docker.enable;

  alloyConfig = ''
    // ── Remote sinks ──────────────────────────────────
    prometheus.remote_write "default" {
      endpoint {
        url = "${cfg.prometheusUrl}"
      }
    }

    loki.write "default" {
      endpoint {
        url = "${cfg.lokiUrl}"
      }
    }

    // ── Node metrics (always on) ──────────────────────
    prometheus.exporter.unix "node" {
      disable_collectors = ["ipvs", "btrfs", "infiniband", "xfs", "zfs"]
      // INFRA-200: textfile collector — oneshot probes (sssd-probe) drop
      // .prom files here and they ride the normal node scrape.
      textfile {
        directory = "/var/lib/alloy-textfile"
      }
      // systemd collector (INFRA-106): exposes node_systemd_unit_state so a
      // FAILED unit on any host can be alerted on fleet-wide — the signal
      // that catches a service with no dedicated exporter whose host
      // node_exporter stays up while only the unit dies. Scoped to
      // .service units below to bound cardinality.
      enable_collectors  = ["systemd"]

      systemd {
        unit_include = ".+\\.service"
      }

      filesystem {
        fs_types_exclude     = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|tmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
        mount_points_exclude = "^/(dev|proc|run/credentials/.+|sys|var/lib/docker/.+)($|/)"
        mount_timeout        = "5s"
      }

      netclass {
        ignored_devices = "^(veth.*|cali.*|[a-f0-9]{15})$"
      }

      netdev {
        device_exclude = "^(veth.*|cali.*|[a-f0-9]{15})$"
      }
    }

    discovery.relabel "node" {
      targets = prometheus.exporter.unix.node.targets

      rule {
        target_label = "instance"
        replacement  = constants.hostname
      }

      rule {
        target_label = "job"
        replacement  = "integrations/node_exporter"
      }
    }

    prometheus.scrape "node" {
      targets    = discovery.relabel.node.output
      forward_to = [prometheus.remote_write.default.receiver]
    }

    // ── Journald logs (always on) ─────────────────────
    loki.relabel "journal" {
      forward_to = [loki.write.default.receiver]

      rule {
        target_label = "instance"
        replacement  = constants.hostname
      }

      rule {
        target_label = "job"
        replacement  = "integrations/node_exporter"
      }
    }

    // INFRA-192: alloy's embedded cadvisor logs "Failed to create existing
    // container ... permission denied" every 60s on docker hosts (~2.8k
    // lines/host/48h) — a known cadvisor-under-LXC artifact, not actionable.
    // Drop it at the source so fleet error-rate sweeps return signal, not
    // this. Anything else flows through untouched.
    loki.process "drop_noise" {
      forward_to = [loki.relabel.journal.receiver]

      stage.drop {
        expression = "Failed to create existing container.*permission denied"
      }
    }

    loki.source.journal "default" {
      max_age    = "12h0m0s"
      forward_to = [loki.process.drop_noise.receiver]
      relabel_rules = loki.relabel.journal_meta.rules
    }

    loki.relabel "journal_meta" {
      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal__boot_id"]
        target_label  = "boot_id"
      }

      rule {
        source_labels = ["__journal__transport"]
        target_label  = "transport"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }

      forward_to = []
    }
  '' + optionalString dockerEnabled ''

    // ── Docker/cadvisor metrics (docker hosts only) ───
    prometheus.exporter.cadvisor "docker" {
      docker_only = true
    }

    discovery.relabel "cadvisor" {
      targets = prometheus.exporter.cadvisor.docker.targets

      rule {
        target_label = "job"
        replacement  = "integrations/docker"
      }

      rule {
        target_label = "instance"
        replacement  = constants.hostname
      }
    }

    prometheus.scrape "cadvisor" {
      targets    = discovery.relabel.cadvisor.output
      forward_to = [prometheus.remote_write.default.receiver]
    }

    // ── Docker logs (docker hosts only) ───────────────
    discovery.docker "docker_logs" {
      host             = "unix:///var/run/docker.sock"
      refresh_interval = "5s"
    }

    discovery.relabel "docker_logs" {
      targets = []

      rule {
        target_label = "job"
        replacement  = "integrations/docker"
      }

      rule {
        target_label = "instance"
        replacement  = constants.hostname
      }

      rule {
        source_labels = ["__meta_docker_container_name"]
        regex         = "/(.*)"
        target_label  = "container"
      }

      rule {
        source_labels = ["__meta_docker_container_log_stream"]
        target_label  = "stream"
      }
    }

    loki.source.docker "docker_logs" {
      host             = "unix:///var/run/docker.sock"
      targets          = discovery.docker.docker_logs.targets
      forward_to       = [loki.write.default.receiver]
      relabel_rules    = discovery.relabel.docker_logs.rules
      refresh_interval = "5s"
    }
  '';

  # ── OTLP gateway (INFRA-47 / ADR-038) ───────────────────────────
  # Turns this host's Alloy into the fleet's central OTLP ingest point.
  # Receives OTLP (gRPC + HTTP) from the PVE metric server and (later)
  # app SDKs, then fans the three signals into the backends already
  # wired above: metrics → Prometheus remote-write, logs → Loki,
  # traces → local Tempo. Reuses prometheus.remote_write.default and
  # loki.write.default from alloyConfig, so the gateway host keeps
  # shipping its own node metrics + journald like every other host.
  gatewayConfig = ''

    // ── OTLP gateway receiver ─────────────────────────
    otelcol.receiver.otlp "gateway" {
      grpc { endpoint = "${cfg.gateway.otlpGrpcAddress}" }
      http { endpoint = "${cfg.gateway.otlpHttpAddress}" }

      output {
        metrics = [otelcol.processor.batch.gateway.input]
        logs    = [otelcol.processor.batch.gateway.input]
        traces  = [otelcol.processor.batch.gateway.input]
      }
    }

    otelcol.processor.batch "gateway" {
      output {
        metrics = [otelcol.exporter.prometheus.gateway.input]
        logs    = [otelcol.exporter.loki.gateway.input]
        traces  = [otelcol.exporter.otlp.tempo.input]
      }
    }

    // metrics → existing Prometheus remote-write sink
    otelcol.exporter.prometheus "gateway" {
      forward_to = [prometheus.remote_write.default.receiver]
    }

    // logs → existing Loki sink
    otelcol.exporter.loki "gateway" {
      forward_to = [loki.write.default.receiver]
    }

    // traces → local Tempo (loopback OTLP; see nix/modules/tempo)
    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "${cfg.gateway.tempoOtlpEndpoint}"
        tls { insecure = true }
      }
    }
  '';
in
{
  options.infra.observability.alloy = {
    enable = mkEnableOption "Grafana Alloy telemetry agent";

    prometheusUrl = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.settings.observability.prometheusRemoteWriteUrl;
      defaultText = lib.literalExpression "config.fleet.settings.observability.prometheusRemoteWriteUrl";
      description = "Prometheus remote-write endpoint URL. Must be non-null when infra.observability.alloy is enabled (asserted).";
    };

    lokiUrl = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.settings.observability.lokiPushUrl;
      defaultText = lib.literalExpression "config.fleet.settings.observability.lokiPushUrl";
      description = "Loki push endpoint URL. Must be non-null when infra.observability.alloy is enabled (asserted).";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra Alloy config appended to the main config. Use for additional scrape targets.";
    };

    gateway = {
      enable = mkEnableOption "OTLP gateway mode — central OTLP ingest fanning metrics/logs/traces into Prometheus/Loki/Tempo (INFRA-47 / ADR-038)";

      otlpGrpcAddress = mkOption {
        type = types.str;
        default = "0.0.0.0:4317";
        description = "Listen address for the OTLP/gRPC receiver. Public on the internal admin net.";
      };

      otlpHttpAddress = mkOption {
        type = types.str;
        default = "0.0.0.0:4318";
        description = "Listen address for the OTLP/HTTP receiver (the PVE metric server pushes here).";
      };

      tempoOtlpEndpoint = mkOption {
        type = types.str;
        default = "127.0.0.1:14317";
        description = ''
          OTLP/gRPC endpoint of the local Tempo trace store. Loopback +
          non-default port so Tempo's receiver does not collide with the
          gateway's own :4317. Must match nix/modules/tempo otlpGrpcAddress.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.prometheusUrl != null;
        message = "infra.observability.alloy.enable is set but infra.observability.alloy.prometheusUrl is null — set fleet.settings.observability.prometheusRemoteWriteUrl (or infra.observability.alloy.prometheusUrl) to the fleet's Prometheus remote-write endpoint.";
      }
      {
        assertion = cfg.lokiUrl != null;
        message = "infra.observability.alloy.enable is set but infra.observability.alloy.lokiUrl is null — set fleet.settings.observability.lokiPushUrl (or infra.observability.alloy.lokiUrl) to the fleet's Loki push endpoint.";
      }
    ];

    # INFRA-200: textfile-collector drop dir — writable by root oneshots
    # (sssd-probe), readable by alloy's node exporter.
    systemd.tmpfiles.rules = [ "d /var/lib/alloy-textfile 0755 root root -" ];

    services.alloy = {
      enable = true;
      configPath = "/etc/alloy";
    };

    environment.etc."alloy/config.alloy".text =
      alloyConfig
      + optionalString cfg.gateway.enable gatewayConfig
      + cfg.extraConfig;

    # OTLP receiver ports — open only on the gateway host, internal net.
    networking.firewall.allowedTCPPorts = lib.optionals cfg.gateway.enable [ 4317 4318 ];

    users.users.alloy = {
      isSystemUser = true;
      group = "alloy";
      extraGroups =
        [ "systemd-journal" ]
        ++ lib.optional dockerEnabled "docker";
    };
    users.groups.alloy = {};
  };
}
