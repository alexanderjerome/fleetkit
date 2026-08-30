{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types concatStringsSep;
  cfg = config.infra.dhcp;
in
{
  options.infra.dhcp = {
    enable = mkEnableOption "Kea DHCPv4 server";

    interface = mkOption {
      type = types.str;
      default = "eth1";
      description = "Network interface to listen on.";
    };

    subnet = mkOption {
      type = types.str;
      example = "192.0.2.0/24";
      description = "CIDR subnet for DHCP allocation.";
    };

    poolStart = mkOption {
      type = types.str;
      example = "192.0.2.50";
      description = "Start of DHCP pool range.";
    };

    poolEnd = mkOption {
      type = types.str;
      example = "192.0.2.99";
      description = "End of DHCP pool range.";
    };

    gateway = mkOption {
      type = types.str;
      example = "192.0.2.1";
      description = "Default gateway advertised to clients.";
    };

    dnsServers = mkOption {
      type = types.listOf types.str;
      default = config.fleet.network.dns_servers;
      defaultText = lib.literalExpression "config.fleet.network.dns_servers";
      example = [ "192.0.2.100" "1.1.1.1" ];
      description = "DNS servers advertised to clients (fleet DNS + public fallback).";
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.network.dns_domain;
      defaultText = lib.literalExpression "config.fleet.network.dns_domain";
      example = "example.lan";
      description = "Domain name advertised to clients. Must be non-null when infra.dhcp is enabled (asserted).";
    };

    validLifetime = mkOption {
      type = types.int;
      default = 43200;
      description = "DHCP lease valid lifetime in seconds.";
    };

    reservations = mkOption {
      type = types.listOf (types.submodule {
        options = {
          hostname = mkOption {
            type = types.str;
            description = "Hostname handed to the client in the lease (Kea `hostname` reservation field).";
          };
          hw-address = mkOption {
            type = types.str;
            description = "Client MAC address the reservation matches on (colon-separated hex, e.g. \"52:54:00:12:34:56\").";
          };
          ip-address = mkOption {
            type = types.str;
            description = "Fixed IPv4 address assigned to the matching client. Must lie inside the served subnet.";
          };
        };
      });
      default = [];
      example = lib.literalExpression ''
        [ { hostname = "printer"; hw-address = "52:54:00:12:34:56"; ip-address = "192.0.2.240"; } ]
      '';
      description = "Static DHCP reservations (MAC → IP).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = cfg.domain != null;
      message = "infra.dhcp.enable is set but infra.dhcp.domain is null — set fleet.network.dns_domain (or infra.dhcp.domain explicitly).";
    }];

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = [ cfg.interface ];
          dhcp-socket-type = "raw";
        };
        control-socket = {
          socket-type = "unix";
          socket-name = "/run/kea/kea-dhcp4.sock";
        };
        hooks-libraries = [
          { library = "${pkgs.kea}/lib/kea/hooks/libdhcp_stat_cmds.so"; }
        ];
        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };
        valid-lifetime = cfg.validLifetime;
        subnet4 = [{
          id = 1;
          subnet = cfg.subnet;
          pools = [{ pool = "${cfg.poolStart} - ${cfg.poolEnd}"; }];
          option-data = [
            { name = "routers"; data = cfg.gateway; }
            { name = "domain-name-servers"; data = concatStringsSep ", " cfg.dnsServers; }
            { name = "domain-name"; data = cfg.domain; }
          ];
          reservations = cfg.reservations;
        }];
      };
    };

    # Kea DHCP Prometheus exporter
    systemd.services.kea-exporter = {
      description = "Prometheus exporter for ISC Kea DHCP";
      after = [ "kea-dhcp4-server.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.prometheus-kea-exporter}/bin/kea-exporter --address 127.0.0.1 --port 9547 /run/kea/kea-dhcp4.sock";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    infra.alloy.extraConfig = ''

      // ── Kea DHCP metrics ────────────────────────────
      prometheus.scrape "kea" {
        targets = [
          {"__address__" = "127.0.0.1:9547"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        job_name = "kea"
      }
    '';

    networking.firewall.allowedUDPPorts = [ 67 68 ];
  };
}
