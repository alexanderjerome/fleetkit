{ config, lib, pkgs, ... }:

# NixOS LXC template factory (INFRA-86 / ADR-047).
#
# Replaces the old hand-run `sk bootstraps`/tofu-file-upload path for
# getting a NixOS LXC template onto PVE. The template is built from the
# SAME nixpkgs this host is deployed with (so it always tracks the
# fleet's pinned NixOS version) and published to the NFS template store
# that every PVE node mounts cluster-wide as the `nix-store` SR.
#
# Two artifacts land in the vztmpl dir:
#   * nixos-lxc-template-x86_64.tar.xz            — stable "latest" alias
#     (the bpg/proxmox emitter references this name verbatim, so a
#     container apply always boots the newest published template)
#   * nixos-lxc-template-<nixos-version>-x86_64.tar.xz  — version-labelled
#     archive, kept for rollback / provenance.
#
# "A version of NixOS available that is not on disk" is decided by a
# `.storepath` marker next to the latest alias: if it already names the
# current template's realized store path, the run is a no-op. So the
# service only does work when the deployed pin produces a template that
# hasn't been published yet — i.e. after a `nix flake update nixpkgs`
# + redeploy of this host, or the first run after the NFS export comes up.

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.build.lxcTemplateFactory;

  # Built here, at this host's deploy time, from this host's pkgs — the
  # versioned wrapper gives the tarball a stable in-store filename.
  template = pkgs.callPackage ../../../images/lxc-template {
    sshPubKey = config.fleet.network.sysadmin_ssh_key;
  };
  version = config.system.nixos.version;

  latestName = "nixos-lxc-template-x86_64.tar.xz";
  versionedName = "nixos-lxc-template-${version}-x86_64.tar.xz";

  publishScript = pkgs.writeShellApplication {
    name = "publish-lxc-template";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      dir="${cfg.nfsTemplateDir}"
      src="${template}/nixos-lxc-template.tar.xz"
      marker="$dir/${latestName}.storepath"

      if [ ! -d "$dir" ]; then
        echo "template dir $dir absent — NFS export not ready; skipping"
        exit 0
      fi

      want="$(readlink -f "$src")"
      if [ -f "$marker" ] && [ "$(cat "$marker")" = "$want" ]; then
        echo "up to date: $want already published (${versionedName}); nothing to do"
        exit 0
      fi

      echo "publishing NixOS LXC template ${version} from $want"
      # Atomic-ish: write to a temp name in the same dir, then rename.
      vtmp="$dir/.${versionedName}.tmp.$$"
      install -m0644 "$want" "$vtmp"
      mv -f "$vtmp" "$dir/${versionedName}"

      ltmp="$dir/.${latestName}.tmp.$$"
      install -m0644 "$want" "$ltmp"
      mv -f "$ltmp" "$dir/${latestName}"

      printf '%s\n' "$want" > "$marker"
      echo "published: ${versionedName} + ${latestName} (latest alias)"
    '';
  };
in
{
  options.infra.build.lxcTemplateFactory = {
    enable = mkEnableOption "automatic NixOS LXC template builds published to the NFS template store";

    nfsTemplateDir = mkOption {
      type = types.str;
      default = "/data/nfs/store/template/cache";
      description = "PVE vztmpl directory inside the NFS export to publish templates into.";
    };

    interval = mkOption {
      type = types.str;
      default = "daily";
      description = "systemd OnCalendar cadence for the freshness check.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.lxc-template-factory = {
      description = "Build + publish NixOS LXC template to the NFS store (INFRA-86)";
      # The NFS export must be live and /data mounted before publishing —
      # otherwise we'd write the template onto the bare root mountpoint.
      after = [ "nfs-server.service" ];
      requires = [ "nfs-server.service" ];
      unitConfig.RequiresMountsFor = [ cfg.nfsTemplateDir ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe publishScript;
      };
    };

    systemd.timers.lxc-template-factory = {
      description = "Periodic NixOS LXC template freshness check (INFRA-86)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        OnBootSec = "5min";
        Persistent = true;
      };
    };
  };
}
