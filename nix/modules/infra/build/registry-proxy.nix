{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.build.registryProxy;
in
{
  options.infra.build.registryProxy = {
    enable = mkEnableOption "Docker registry pull-through proxy (caches Docker Hub, ghcr.io, etc.)";

    port = mkOption {
      type = types.port;
      default = 3128;
      description = "Port the registry proxy listens on.";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/lib/docker-registry-proxy";
      description = "Directory for cached Docker images.";
    };

    registries = mkOption {
      type = types.str;
      default = "k8s.gcr.io gcr.io quay.io ghcr.io docker.io";
      description = "Space-separated list of registries to cache.";
    };
  };

  config = mkIf cfg.enable {
    infra.integrations.docker.enable = lib.mkDefault true;
    virtualisation.oci-containers.backend = "docker";

    virtualisation.oci-containers.containers.docker-registry-proxy = {
      image = "ghcr.io/rpardini/docker-registry-proxy:latest";
      autoStart = true;
      ports = [ "${toString cfg.port}:3128" ];
      volumes = [
        "${cfg.cacheDir}:/docker_mirror_cache"
        "docker-registry-proxy-certs:/ca"
      ];
      environment = {
        REGISTRIES = cfg.registries;
        ENABLE_MANIFEST_CACHE = "true";
      };
      extraOptions = [
        "--label=komodo.skip"
      ];
    };

    systemd.tmpfiles.settings."10-registry-proxy" = {
      "${cfg.cacheDir}".d = { mode = "0755"; user = "root"; group = "root"; };
    };

    infra.services.registry = {
      port = cfg.port;
      caddy.enable = false;
      description = "Docker registry pull-through proxy (Docker Hub, ghcr.io, quay.io)";
      category = "build";
      tags = [ "docker" "internal" ];
    };
  };
}
