{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.build.builder;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
in
{
  options.infra.build.builder = {
    enable = mkEnableOption "Nix remote builder + harmonia binary cache";

    # 4 jobs × 2 cores fills the 8-vCPU container without single-threading
    # large derivations (bitcoin-core, rust workspaces). The old default
    # of 8 jobs × 1 core meant any one build was stuck on a single core.
    maxJobs = mkOption {
      type = types.int;
      default = 4;
      description = "Maximum number of parallel nix build jobs.";
    };

    cores = mkOption {
      type = types.int;
      default = 2;
      description = "Number of CPU cores per build job.";
    };

    trustedUsers = mkOption {
      type = types.listOf types.str;
      default = [ "root" "sysadmin" ];
      description = "Users trusted to manage the Nix store.";
    };

    cacheBindAddress = mkOption {
      type = types.str;
      default = "[::]:5000";
      description = "Address:port harmonia binary cache listens on.";
    };
  };

  config = mkIf cfg.enable {
    # Builder needs Docker for container builds.
    infra.integrations.docker.enable = true;

    nix.settings = {
      max-jobs = cfg.maxJobs;
      cores = cfg.cores;
      trusted-users = cfg.trustedUsers;
      substituters = lib.mkAfter [
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = lib.mkAfter [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    # Cache signing key persisted in SOPS so a rebuild of the build CT
    # restores the SAME key — pubkey stays stable across redeploys, no
    # fleet-wide trusted-public-keys update required. Previously the
    # nix-cache-keygen systemd-service generated a fresh key whenever
    # /var/lib/nix-cache/ was empty, which forced a cumbersome rotation
    # on every from-scratch CT rebuild.
    #
    # Rotation now: regenerate the key pair locally, replace the SOPS
    # entry, replace nix/secrets/secrets/keys/builder-cache-pub-key.pem,
    # deploy the build host, then fleet-redeploy.
    sops.secrets."services/builder/cache_signing_priv_key" = sopsLib.mkSecret {
      owner = "harmonia";
      group = "harmonia";
      mode = "0400";
      restartUnits = [ "harmonia.service" ];
    };

    # nixpkgs 26.05 moved harmonia under the `cache` sub-attr. Both
    # `services.harmonia.enable` and `services.harmonia.settings` are
    # deprecated aliases of `services.harmonia.cache.enable` /
    # `services.harmonia.cache.settings`. signKeyPaths was already
    # under `cache`.
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [
        config.sops.secrets."services/builder/cache_signing_priv_key".path
      ];
      settings.bind = cfg.cacheBindAddress;
    };

    # Ship Harmonia cache metrics to Prometheus
    infra.observability.alloy.extraConfig = ''

      // ── Harmonia binary cache metrics ───────────────
      prometheus.scrape "harmonia" {
        targets = [
          {"__address__" = "127.0.0.1:5000"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        metrics_path = "/metrics"
        job_name = "harmonia"
      }
    '';

    infra.services.cache = {
      port = 5000;
      caddy.enable = false;
      description = "Harmonia Nix binary cache";
      category = "build";
      tags = [ "nix" "internal" ];
    };
  };
}
