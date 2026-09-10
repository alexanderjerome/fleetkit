{ config, lib, ... }:

# Nix store hygiene for every fleet host: the GC policy that keeps a tight
# rootfs from filling with old system generations.
#
# Split out of ./default.nix rather than living beside the other nix
# settings because it declares an option, and a module that declares
# options must put all of its config under `config` — default.nix is a
# bare config attrset and restructuring it wholesale to add one knob is a
# worse trade than one focused file.
#
# Two independent bounds, because they fail differently:
#
#   * AGE — `nix.gc.options` (--delete-older-than). Guarantees a rollback
#     window. Says nothing about how many generations fit in it.
#   * COUNT — `infra.nix.gc.keepGenerations`. Guarantees a ceiling. Says
#     nothing about how far back you can roll.
#
# You want both. `nix.gc` only offers the first: its option surface is
# exactly {automatic, dates, options, persistent, randomizedDelaySec} —
# there is no count knob to set, which is why the count bound here is a
# pre-hook on the GC unit rather than more `nix.gc` config.
#
# History, three incidents on the same fault line:
#
#   INFRA-108   backend-v2 (16 G root, several node-heavy deploys/day)
#               accumulated 5.8 GiB / ~800k inodes of generations under a
#               weekly/14d window and tripped both disk-warning and
#               disk-critical (89% bytes, 98% inodes). Tightened to
#               daily/7d.
#   AIRDROP-134 The same host, still filling under 7d — a console redeploy
#               died at 95%. Consumer reached for `lib.mkForce` on
#               nix.gc.options to get 3d, which is the tell that this
#               policy was hard-set where it should have been a default.
#               Hence mkDefault throughout below.
#   jeirslab    infisical (8 G root) ENOSPC'd mid-npm-build across four
#               consecutive deploys in one evening. Fixed by growing the
#               disk to 32 G.
#
# What the min-free/max-free tier is and is NOT for: it triggers an
# emergency collection inside the nix-daemon when free space dips below
# min-free during a copy or build, which protects an in-flight
# `colmena apply` from dying halfway. It does not bound growth. It only
# drops paths nothing references, so a live generation is invisible to
# it, and it does nothing at all for inode exhaustion. Both incidents
# above recorded it failing to help; it is a seatbelt, not a diet.
#
# Nor does the count bound below rescue a same-day deploy burst: it runs
# when the timer fires, and unlinking a generation frees no bytes until
# the collector runs behind it. It bounds steady state. The fix for
# churn is a root disk sized for the build.

let
  cfg = config.infra.nix.gc;
in
{
  options.infra.nix.gc.keepGenerations = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = 10;
    example = 3;
    description = ''
      How many system-profile generations to keep, regardless of age.

      Trimmed immediately before each automatic GC run (as an
      `ExecStartPre` on nix-gc.service) so the collector frees the
      unlinked paths in the same pass.

      This bounds what the age window cannot. `--delete-older-than` is
      purely age-based, so a host deployed a dozen times inside the
      retention window keeps a dozen generations, all of them "recent".
      The two bounds compose: a generation is kept only if it is both
      young enough and new enough.

      Set to null to disable the count bound and retain by age alone.
      Has no effect when `nix.gc.automatic` is false.
    '';
  };

  config = {
    # All mkDefault: a host on a tight disk or with unusual churn tunes
    # its own window without needing mkForce to get out from under the
    # framework (see AIRDROP-134 above).
    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "daily";
      options = lib.mkDefault "--delete-older-than 7d";
      # Spread the fleet's collections out; a synchronised fleet-wide GC
      # is a synchronised fleet-wide IO stall on shared storage.
      randomizedDelaySec = lib.mkDefault "1h";
    };

    nix.settings.min-free = lib.mkDefault (1024 * 1024 * 1024); # 1 GiB
    nix.settings.max-free = lib.mkDefault (5 * 1024 * 1024 * 1024); # 5 GiB

    # nixpkgs defines nix-gc.service unconditionally and gates only the
    # *timer* on `automatic`, so this guard is not about unit existence.
    # It is intent: a host that opted out of scheduled collection should
    # not get generations trimmed behind its back, including on a manual
    # `systemctl start nix-gc`. Re-enable by setting nix.gc.automatic.
    systemd.services.nix-gc = lib.mkIf
      (config.nix.gc.automatic && cfg.keepGenerations != null)
      {
        serviceConfig.ExecStartPre = [
          "${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --delete-generations +${toString cfg.keepGenerations}"
        ];
      };
  };
}
