# Hydra CI — Nix-native continuous integration on the builder host.
#
# Uses Hydra's declarative projects feature: a spec.json in the repo
# defines all jobsets. Hydra evaluates it on every check interval and
# auto-creates/updates jobsets. No API calls needed.
#
# Usage in hosts.nix:
#   infra.build.hydra.enable = true;
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf mkDefault types;
  cfg = config.infra.build.hydra;
  builderCfg = config.infra.build.builder;
  sopsLib = import ../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;
in
{
  options.infra.build.hydra = {
    enable = mkEnableOption "Hydra CI server on the builder host";

    smtp = {
      enable = mkEnableOption "SMTP email relay via Resend (msmtp) for Hydra build notifications";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "TCP port for the hydra-server web UI. Opened in the firewall, reverse-proxied by the `hydra.<domain.internal>` Caddy vhost, and scraped by Alloy for HTTP metrics.";
    };

    listenHost = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address hydra-server binds to. Default listens on all interfaces; set to 127.0.0.1 to serve only through the Caddy vhost.";
    };

    hydraUrl = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.internal != null
                then "https://hydra.${config.fleet.settings.domain.internal}" else null;
      defaultText = lib.literalExpression ''"https://hydra.''${config.fleet.settings.domain.internal}"'';
      description = "Canonical external URL Hydra advertises for itself (links in the UI and notification emails). Asserted non-null when the module is enabled — set it explicitly if fleet.settings.domain.internal is null.";
    };

    notificationSender = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.base != null
                then "hydra@${config.fleet.settings.domain.base}" else null;
      defaultText = lib.literalExpression ''"hydra@''${config.fleet.settings.domain.base}"'';
      description = "From: address for Hydra build-notification emails (also used as the msmtp envelope sender when smtp.enable is set). Asserted non-null when the module is enabled.";
    };

    maxConcurrentEvals = mkOption {
      type = types.int;
      default = 2;
      description = "Value for Hydra's `max_concurrent_evals` — how many jobset evaluations may run in parallel. Keep low on builder hosts that also run real builds; each eval can use gigabytes of memory.";
    };

    project = mkOption {
      type = types.str;
      default = config.fleet.settings.name;
      defaultText = lib.literalExpression "config.fleet.settings.name";
      description = "Name of the Hydra project that holds the declaratively-managed jobsets (spec.json in the repo).";
    };
  };

  config = mkIf (builderCfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.hydraUrl != null && config.fleet.settings.domain.internal != null;
        message = "infra.build.hydra.enable is set but fleet.settings.domain.internal is null — the hydra.<domain.internal> vhost and infra.build.hydra.hydraUrl need it (or set hydraUrl explicitly AND domain.internal for the vhost).";
      }
      {
        assertion = cfg.notificationSender != null;
        message = "infra.build.hydra.enable is set but infra.build.hydra.notificationSender is null — set fleet.settings.domain.base (or notificationSender explicitly).";
      }
    ];

    services.hydra = {
      enable = true;
      hydraURL = cfg.hydraUrl;
      listenHost = cfg.listenHost;
      port = cfg.port;
      notificationSender = cfg.notificationSender;
      useSubstitutes = true;

      extraConfig = ''
        max_concurrent_evals = ${toString cfg.maxConcurrentEvals}
        evaluator_max_memory_size = 4096
        binary_cache_public_uri = http://localhost:5000
        enable_prometheus_metrics = 1
        max_output_size = 10737418240

        <nix-eval>
          allow-import-from-derivation = false
        </nix-eval>
      '';

      extraEnv = {
        NIX_CONFIG = "extra-experimental-features = nix-command flakes\naccept-flake-config = true\n";
      };
    };

    nix.settings.trusted-users = [ "hydra" "hydra-queue-runner" ];
    nix.settings.experimental-features = [ "nix-command" "flakes" ];


    # NixOS host closures are built via colmena (which uses the builder
    # as a remote builder). Hydra focuses on app package builds only.

    # ── Prometheus metrics ──
    #
    # Two separate Hydra exporters with different scopes:
    #
    #  - hydra-queue-runner :9198
    #      Internal queue/dispatcher timing counters. Tells us how busy the
    #      build dispatcher is and how much work is flowing through the queue
    #      monitor. Does NOT expose build counts, queue length, or success
    #      rate — those metrics require querying Hydra's postgres directly
    #      (tracked in follow-up: postgres_exporter for hydra DB).
    #
    #  - hydra-server (web UI) :3000/metrics
    #      HTTP request histogram (latency by controller/action/status). Useful
    #      for web UI health — doesn't inform build activity.
    infra.observability.alloy.extraConfig = ''

      // ── Hydra CI metrics ────────────────────────────
      prometheus.scrape "hydra_queue_runner" {
        targets = [
          {"__address__" = "127.0.0.1:9198"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        metrics_path = "/metrics"
        job_name = "hydra_queue_runner"
      }

      prometheus.scrape "hydra_server" {
        targets = [
          {"__address__" = "127.0.0.1:${toString cfg.port}"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        metrics_path = "/metrics"
        job_name = "hydra_server"
      }
    '';

    # Caddy reverse proxy for HTTPS access
    infra.ingress.virtualHosts."hydra.${config.fleet.settings.domain.internal}".extraConfig = ''
      reverse_proxy http://127.0.0.1:${toString cfg.port}
    '';

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    infra.services.hydra = {
      port = cfg.port;
      description = "Hydra Nix CI — build status, jobsets, and metrics";
      category = "build";
      tags = [ "ci" "nix" "web-ui" ];
    };

    # ── msmtp SMTP relay for Hydra build notifications ──
    sops.secrets = lib.optionalAttrs cfg.smtp.enable {
      "services/resend/smtp_secret" = sopsLib.mkSecret {};
      "services/resend/smtp_host" = sopsLib.mkSecret {};
      "services/resend/smtp_username" = sopsLib.mkSecret {};
      "services/resend/smtp_port" = sopsLib.mkSecret {};
    };

    sops.templates."msmtp-config" = mkIf cfg.smtp.enable (sopsLib.mkTemplate {
      content = ''
        defaults
        auth           on
        tls            on
        tls_starttls   on
        logfile        /var/log/msmtp.log

        account        resend
        host           ${p."services/resend/smtp_host"}
        port           ${p."services/resend/smtp_port"}
        from           ${cfg.notificationSender}
        user           ${p."services/resend/smtp_username"}
        password       ${p."services/resend/smtp_secret"}

        account default : resend
      '';
    });

    programs.msmtp = mkIf cfg.smtp.enable {
      enable = true;
      setSendmail = true;
      defaults.aliases = "/etc/aliases";
      accounts.resend = {
        host = "smtp.resend.com";
        port = 587;
        auth = true;
        tls = true;
        tls_starttls = true;
        from = cfg.notificationSender;
        user = "resend";
        passwordeval = "cat ${config.sops.secrets."services/resend/smtp_secret".path}";
      };
    };
  };
}
