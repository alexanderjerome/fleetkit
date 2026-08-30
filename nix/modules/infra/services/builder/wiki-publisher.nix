{ config, lib, pkgs, ... }:

# In-fleet wiki refresh (INFRA-150). Replaces the retired GitHub doc
# workflows (INFRA-148, never worked): nix-builder rebuilds the handbook
# from the repo tip on a timer and rsyncs the static site to the docs
# host, which serves the mutable /var/lib/wiki/site (seeded from its own
# deploy-time build, see hosts/pve/docs.nix). `nix build <ref>#wiki-site`
# re-derives every generated projection (ADR pages, service catalog,
# topology) per ADR-078 — no repo checkout and no GH runner involved.
#
# The docs CT itself (512M / 1 core) cannot evaluate the flake, which is
# why the build runs here and only static files travel.

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.builder.wikiPublisher;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };
  p = config.sops.placeholder;

  publish = pkgs.writeShellApplication {
    name = "wiki-publish";
    runtimeInputs = [ config.nix.package pkgs.git pkgs.rsync pkgs.openssh pkgs.coreutils ];
    # SC2016: the credential-helper string must NOT expand $GITHUB_TOKEN
    # here — git's runtime shell expands it from the service environment.
    excludeShellChecks = [ "SC2016" ];
    text = ''
      set -euo pipefail
      base=/var/lib/wiki-publisher
      repo=$base/repo
      mkdir -p "$base"
      # The flake's app-repo inputs are `git+file:./submodules/...` — they
      # need REAL submodule checkouts, so a `github:` tarball eval can never
      # work. Maintain a persistent recursive clone instead and build from
      # it, exactly like a developer checkout. Auth: GITHUB_TOKEN from the
      # sops-rendered EnvironmentFile via an inline credential helper.
      cred='!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
      if [ ! -d "$repo/.git" ]; then
        git -c credential.helper="$cred" clone --branch "${cfg.branch}" \
          --recurse-submodules "${cfg.repoUrl}" "$repo"
      fi
      cd "$repo"
      git -c credential.helper="$cred" fetch origin "${cfg.branch}"
      git reset --hard "origin/${cfg.branch}"
      git -c credential.helper="$cred" submodule update --init --recursive
      # The out-link doubles as a GC root between runs.
      nix build .#wiki-site --out-link "$base/result"
      echo "built $(readlink -f "$base/result") — publishing to ${cfg.target}:${cfg.targetDir}"
      rsync -rlpt --delete "$base/result"/ "${cfg.target}:${cfg.targetDir}/"
      echo "published"
    '';
  };
in
{
  options.infra.builder.wikiPublisher = {
    enable = mkEnableOption "timer that rebuilds the handbook from the repo tip and rsyncs it to the docs host (INFRA-150)";

    repoUrl = mkOption {
      type = types.str;
      example = "https://github.com/example-org/deployments.git";
      description = "HTTPS clone URL for the deployments repo (token auth).";
    };

    branch = mkOption {
      type = types.str;
      default = "nightly";
      description = "Branch whose tip the handbook is built from.";
    };

    target = mkOption {
      type = types.str;
      example = "root@192.0.2.25";
      description = "rsync/ssh destination for the docs host.";
    };

    targetDir = mkOption {
      type = types.str;
      default = "/var/lib/wiki/site";
      description = "Directory the docs host serves the handbook from.";
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 06:15:00";
      description = "systemd OnCalendar expression for the refresh.";
    };
  };

  config = mkIf (config.infra.builder.enable && cfg.enable) {
    # GitHub machine-user token: the flake and its inputs may live in
    # private repos; nix reads the token via NIX_CONFIG access-tokens.
    sops.secrets."integrations/github/machine_user_token" =
      sopsLib.mkSecret { restartUnits = [ "wiki-publisher.service" ]; };

    sops.templates."wiki-publisher-env" = sopsLib.mkTemplate {
      content = ''
        NIX_CONFIG=access-tokens = github.com=${p."integrations/github/machine_user_token"}
        GITHUB_TOKEN=${p."integrations/github/machine_user_token"}
      '';
    };

    systemd.services.wiki-publisher = {
      description = "Rebuild the fleet handbook from the repo tip and publish to the docs host";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = config.sops.templates."wiki-publisher-env".path;
        ExecStart = "${publish}/bin/wiki-publish";
      };
    };

    systemd.timers.wiki-publisher = {
      description = "Daily fleet-handbook refresh (INFRA-150)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };
  };
}
