{ config, lib, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.tempo;
in
# Tempo — single-binary distributed trace store (INFRA-47 / ADR-038).
#
# Co-located with the Alloy OTLP gateway on the `otel` CT. Alloy is the
# ONLY writer: it forwards traces to Tempo's OTLP receiver, which binds
# loopback on a non-default port (14317) so it never collides with the
# gateway's public :4317. Grafana (CT 104, `grafana`) queries traces over
# the HTTP API (:3200).
#
# Storage is local disk (StateDirectory → /var/lib/tempo). Re-creatable:
# traces are low-value, short-retention observability data, so the host
# carries no `protect`.
{
  options.infra.tempo = {
    enable = mkEnableOption "Tempo trace store (INFRA-47 / ADR-038)";

    httpPort = mkOption {
      type = types.port;
      default = 3200;
      description = "Tempo HTTP/query API port — the Grafana Tempo datasource target.";
    };

    otlpGrpcAddress = mkOption {
      type = types.str;
      default = "127.0.0.1:14317";
      description = ''
        OTLP/gRPC receiver address. Loopback + non-default port: only the
        local Alloy gateway writes here, and it must not clash with the
        gateway's own :4317. Must match infra.alloy.gateway.tempoOtlpEndpoint.
      '';
    };

    retention = mkOption {
      type = types.str;
      default = "168h";
      description = "Trace block retention (compactor block_retention). Default 7 days.";
    };

    mcpServer.enable = mkEnableOption ''
      Tempo's built-in MCP server (streamable HTTP at /api/mcp on the query
      frontend). Lets AI tooling run TraceQL against this Tempo over MCP.
      Opt-in per host so it only runs where we want it'';
  };

  config = mkIf cfg.enable {
    services.tempo = {
      enable = true;
      settings = {
        server = {
          http_listen_port = cfg.httpPort;
          # Internal gRPC (querier/ingester). Distinct from the OTLP
          # receiver port below and from Alloy's :4317.
          grpc_listen_port = 9096;
        };

        # Built-in MCP server, served at :3200/api/mcp (streamable HTTP).
        # Opt-in via infra.tempo.mcpServer.enable on the host.
        query_frontend = mkIf cfg.mcpServer.enable {
          mcp_server.enabled = true;
        };

        distributor.receivers.otlp.protocols.grpc.endpoint = cfg.otlpGrpcAddress;

        ingester.max_block_duration = "5m";

        compactor.compaction.block_retention = cfg.retention;

        storage.trace = {
          backend = "local";
          wal.path = "/var/lib/tempo/wal";
          local.path = "/var/lib/tempo/blocks";
        };
      };
    };

    # services.tempo runs DynamicUser; StateDirectory creates and owns
    # /var/lib/tempo so the WAL + block paths above are writable.
    systemd.services.tempo.serviceConfig.StateDirectory = "tempo";

    # Query API reachable from the grafana host. OTLP receiver stays
    # loopback, so only the HTTP port is opened.
    networking.firewall.allowedTCPPorts = [ cfg.httpPort ];
  };
}
