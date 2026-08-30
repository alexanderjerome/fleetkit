{ config, lib, pkgs, ... }:

# apt-cacher-ng — caching HTTP proxy for Debian/Ubuntu apt repos.
# Used by the dev-VM cloud-init snippets (nix/fleet/resources.nix) to
# avoid hitting deb.debian.org for every fresh VM. Nixpkgs ships the
# package but no NixOS service module, so this module wires it.

let
  cfg = config.infra.apt-cacher-ng;
  acng = pkgs.apt-cacher-ng;
  acngConfDir = pkgs.runCommand "apt-cacher-ng-conf" {} ''
    mkdir -p $out
    cp ${acng}/etc/apt-cacher-ng/*.conf $out/
    cat > $out/fleet.conf <<EOF
Port: ${toString cfg.port}
CacheDir: ${cfg.cacheDir}
LogDir: ${cfg.logDir}
PidFile: /run/apt-cacher-ng/apt-cacher-ng.pid
SocketPath: /run/apt-cacher-ng/socket
ForeGround: 1
BindAddress: ${cfg.bindAddress}
ExThreshold: ${toString cfg.expireDays}
EOF
  '';
in
{
  options.infra.apt-cacher-ng = {
    enable = lib.mkEnableOption "apt-cacher-ng caching proxy for apt repos";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3142;
      description = "TCP port apt-cacher-ng listens on.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to bind to. Default 0.0.0.0 so internal VMs can reach it.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/apt-cacher-ng";
      description = "Cache directory.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/apt-cacher-ng";
      description = "Log directory.";
    };

    expireDays = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Days before stale cache entries are eligible for expiry.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 apt-cacher-ng apt-cacher-ng -"
      "d ${cfg.logDir}   0755 apt-cacher-ng apt-cacher-ng -"
      "d /run/apt-cacher-ng 0755 apt-cacher-ng apt-cacher-ng -"
    ];

    users.users.apt-cacher-ng = {
      isSystemUser = true;
      group = "apt-cacher-ng";
      home = cfg.cacheDir;
    };
    users.groups.apt-cacher-ng = {};

    systemd.services.apt-cacher-ng = {
      description = "apt-cacher-ng caching proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "apt-cacher-ng";
        Group = "apt-cacher-ng";
        ExecStart = "${acng}/bin/apt-cacher-ng -c ${acngConfDir}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "apt-cacher-ng";
        StateDirectory = "apt-cacher-ng";
        LogsDirectory = "apt-cacher-ng";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    infra.services.apt-cacher-ng = {
      port = cfg.port;
      description = "apt-cacher-ng caching proxy for Debian/Ubuntu";
      category = "platform";
      tags = [ "proxy" "apt" ];
    };
  };
}
