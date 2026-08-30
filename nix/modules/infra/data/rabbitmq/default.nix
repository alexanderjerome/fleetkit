# RabbitMQ — message broker for event-driven data pipelines.
#
# Sits between upstream databases and downstream consumers
# (summary jobs, real-time subscriptions, notifications).
#
# Usage in hosts.nix:
#   infra.data.rabbitmq.enable = true;
#   infra.data.rabbitmq.appPassword = "...";
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf mkDefault types;
  cfg = config.infra.data.rabbitmq;
in
{
  options.infra.data.rabbitmq = {
    enable = mkEnableOption "RabbitMQ message broker";

    port = mkOption {
      type = types.port;
      default = 5672;
      description = "AMQP listener port. Opened in the firewall; RabbitMQ binds it on all interfaces.";
    };

    managementPort = mkOption {
      type = types.port;
      default = 15672;
      description = "Management-plugin HTTP port. Opened in the firewall and reverse-proxied by the `rabbitmq.<domain.internal>` Caddy vhost.";
    };

    appUser = mkOption {
      type = types.str;
      default = config.fleet.settings.name;
      defaultText = lib.literalExpression "config.fleet.settings.name";
      description = "Application user provisioned with full permissions on the / vhost and the management tag.";
    };

    appPassword = mkOption {
      type = types.str;
      example = "change-me";
      description = ''
        Password for the application user. WARNING: lands world-readable
        in the nix store via the provisioning script — acceptable only
        because the broker is reachable solely from the fleet-internal
        network. Rotate to a SOPS-sourced mechanism if that changes.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = config.fleet.settings.domain.internal != null;
      message = "infra.data.rabbitmq.enable is set but fleet.settings.domain.internal is null — the rabbitmq.<domain.internal> management vhost needs it.";
    }];

    services.rabbitmq = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = cfg.port;
      managementPlugin.enable = true;
      managementPlugin.port = cfg.managementPort;
      # Prometheus metrics endpoint on :15692 (INFRA-128). Without this plugin
      # the Alloy scrape below hits a closed port (up=0, no rabbitmq_* series)
      # and the MVP App Backend dashboard's RabbitMQ panels stay empty.
      plugins = [ "rabbitmq_prometheus" ];
    };

    # Alloy metrics via RabbitMQ's built-in Prometheus endpoint
    infra.observability.alloy.extraConfig = ''

      // ── RabbitMQ metrics ────────────────────────────
      prometheus.scrape "rabbitmq" {
        targets = [
          {"__address__" = "127.0.0.1:15692"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        job_name = "rabbitmq"
      }
    '';

    # Declare the application user (persists across restarts)
    systemd.services.rabbitmq-user-setup = {
      description = "RabbitMQ user setup";
      after = [ "rabbitmq.service" ];
      requires = [ "rabbitmq.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "rabbitmq";
      };
      environment.HOME = "/var/lib/rabbitmq";
      script = ''
        ${pkgs.rabbitmq-server}/bin/rabbitmqctl add_user ${cfg.appUser} ${cfg.appPassword} 2>/dev/null || \
          ${pkgs.rabbitmq-server}/bin/rabbitmqctl change_password ${cfg.appUser} ${cfg.appPassword}
        ${pkgs.rabbitmq-server}/bin/rabbitmqctl set_permissions -p / ${cfg.appUser} ".*" ".*" ".*"
        ${pkgs.rabbitmq-server}/bin/rabbitmqctl set_user_tags ${cfg.appUser} management
      '';
    };

    infra.ingress.enable = mkDefault true;
    infra.ingress.virtualHosts."rabbitmq.${config.fleet.settings.domain.internal}".extraConfig = ''
      reverse_proxy http://127.0.0.1:${toString cfg.managementPort}
    '';

    networking.firewall.allowedTCPPorts = [
      cfg.port
      cfg.managementPort
      15692  # Prometheus metrics
    ];

    infra.services.rabbitmq = {
      port = cfg.managementPort;
      description = "RabbitMQ message broker (management UI)";
      category = "data";
      tags = [ "messaging" "web-ui" ];
    };
  };
}
