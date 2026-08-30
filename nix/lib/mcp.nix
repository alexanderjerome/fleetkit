# Shared helper for declaring per-host MCP servers (ADR-057).
#
# Usage (from a host's hostsRegistry / any module under nix/modules/*/):
#   let mcpLib = import ../../lib/mcp.nix { inherit lib pkgs; };
#   in {
#     infra.integrations.mcp.enable = true;
#     infra.integrations.mcp.servers.postgres = mcpLib.mkMCP {
#       package = pkgs.postgres-mcp;          # or: command = "...";
#       args    = [ "--access-mode" "restricted" ];
#       port    = 9110;
#       access  = "admin";                    # internal | staff | admin
#       environment.DATABASE_URI = "postgresql://localhost/app";
#     };
#   }
#
# `mkMCP` returns one `infra.integrations.mcp.servers.<name>` submodule value — it is thin
# sugar over that submodule (defaults + light validation), mirroring the
# sopsLib.mk* helpers. The module (nix/modules/mcp/default.nix) does the real
# work: a systemd service per server, stdio→SSE bridging via mcp-proxy, and
# network exposure per access tier.

{ lib, pkgs }:

{
  # Build one infra.integrations.mcp.servers.<name> entry.
  #
  #   package      A package whose main program is the MCP server. Either this
  #                or `command` is required; `package` wins if both are set.
  #   command      Explicit executable path/name (e.g. for npx/uvx launchers).
  #   args         Argument list passed to the server (default []).
  #   transport    Native transport of the server: "stdio" (default — wrapped
  #                to SSE by mcp-proxy), "sse", or "http" (server binds its own
  #                port; pass the port via args/environment).
  #   port         Network port the server is reachable on. Required.
  #   access       "internal" (firewall-open on the internal net, no auth — the
  #                tempo/grafana pattern), "staff" (Authentik login), or "admin"
  #                (platform-admins group). Defaults to "admin" — safe by default.
  #   environment  Env vars for the server process (SOPS secret paths welcome).
  #   description  One-line human description (service catalog + systemd unit).
  #   tags         Service-catalog tags.
  mkMCP =
    { package ? null
    , command ? null
    , args ? [ ]
    , transport ? "stdio"
    , port
    , access ? "admin"
    , environment ? { }
    , description ? ""
    , tags ? [ ]
    }:
    assert lib.assertMsg (package != null || command != null)
      "mkMCP: set either `package` or `command`.";
    {
      enable = true;
      inherit args transport port access environment description tags;
      command = if package != null then lib.getExe package else command;
    };
}
