{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.docker;
in
{
  options.infra.docker = {
    enable = mkEnableOption "Docker daemon";

    dataRoot = mkOption {
      type = types.str;
      default = "/var/lib/docker";
      description = "Root directory for Docker storage.";
    };

    logDriver = mkOption {
      type = types.str;
      default = "journald";
      description = "Docker logging driver.";
    };

    registryMirror = mkOption {
      type = types.str;
      default = "";
      example = "http://192.0.2.11:3128";
      description = "URL of a Docker registry pull-through proxy (e.g. an in-fleet cache). Empty string (default) disables the mirror.";
    };
  };

  config = mkIf cfg.enable {
    # Docker bridge networking requires IP forwarding and permissive firewall
    # rules on bridge interfaces. In unprivileged LXC, Docker's iptables
    # integration is limited, so we explicitly trust Docker bridge traffic.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    networking.firewall.trustedInterfaces = [ "docker0" "br-+" ];

    virtualisation.docker = {
      enable = true;
      daemon.settings = {
        "log-driver" = cfg.logDriver;
        # Disable containerd snapshotter — use legacy graphdriver.
        # Required for images with non-standard media types (Hiro, etc.)
        "features" = { "containerd-snapshotter" = false; };
      } // lib.optionalAttrs (cfg.dataRoot != "/var/lib/docker") {
        "data-root" = cfg.dataRoot;
      } // lib.optionalAttrs (cfg.registryMirror != "") {
        "registry-mirrors" = [ cfg.registryMirror ];
        "insecure-registries" = [ cfg.registryMirror ];
      };
    };
  };
}
