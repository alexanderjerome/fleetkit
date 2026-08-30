# Valkey — Redis-compatible cache.
#
# Two deployment shapes:
#   - Co-located sidecar (default): bindAddress = "127.0.0.1", no auth, no
#     firewall opening. Use for caching API queries on the same host as
#     the consumer (dash today).
#   - Dedicated cache host: bindAddress = "<internal-ip>" +
#     allowedSubnets = [ "<fleet-lan-cidr>" ]. Use when another LXC needs
#     network access (e.g. an app host → its dedicated valkey host).
#
# Usage in hosts.nix:
#   infra.valkey.enable = true;                       # sidecar form
#   infra.valkey.bindAddress = "192.0.2.16";          # dedicated form
#   infra.valkey.allowedSubnets = [ "192.0.2.0/24" ];
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.valkey;

  configFile = pkgs.writeText "valkey.conf" ''
    bind ${cfg.bindAddress}
    port ${toString cfg.port}
    maxmemory ${cfg.maxMemory}
    maxmemory-policy allkeys-lru
    save ""
    daemonize no
    loglevel notice
    ${lib.optionalString (cfg.bindAddress != "127.0.0.1") ''
      # Protected mode is fine on a private subnet; auth is enforced at the
      # firewall layer via allowedSubnets, not at the valkey protocol.
      protected-mode no
    ''}
  '';
in
{
  options.infra.valkey = {
    enable = mkEnableOption "Valkey cache (Redis-compatible)";

    port = mkOption {
      type = types.port;
      default = 6379;
      description = "TCP port valkey listens on. Only opened in the firewall (scoped to `allowedSubnets`) in the dedicated-host form; the loopback sidecar form needs no firewall opening.";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Address valkey binds to. Default is loopback (sidecar form).
        Set to the host's internal IP for a dedicated cache LXC reachable
        from sibling LXCs on the internal subnet.
      '';
    };

    allowedSubnets = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        CIDRs allowed to reach the valkey port at the firewall level.
        Empty (default) keeps the port closed everywhere — appropriate
        for bindAddress = 127.0.0.1. Open to the fleet LAN CIDR
        (fleet.settings.network.lanCidr) for a dedicated cache host.
      '';
    };

    maxMemory = mkOption {
      type = types.str;
      default = "256mb";
      description = "Maximum memory for cache. Evicts LRU when full.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.valkey = {
      description = "Valkey cache (Redis-compatible)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.valkey}/bin/valkey-server ${configFile}";
        DynamicUser = true;
        StateDirectory = "valkey";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    networking.firewall.extraCommands = lib.mkIf (cfg.allowedSubnets != []) (
      lib.concatStringsSep "\n" (map (cidr: ''
        iptables -A nixos-fw -p tcp -s ${cidr} --dport ${toString cfg.port} -j nixos-fw-accept
      '') cfg.allowedSubnets)
    );
  };
}
