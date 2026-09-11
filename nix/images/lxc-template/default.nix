{ pkgs
  # Operator SSH public key baked into the template's root account —
  # fleets pass config.fleet.network.sysadmin_ssh_key.
, sshPubKey ? throw "images/lxc-template: pass sshPubKey (e.g. config.fleet.network.sysadmin_ssh_key)"
  # In-fleet binary caches baked into the template — fleets pass
  # config.fleet.settings.cache.{substituters,trustedPublicKeys}. See the
  # nix.settings note in by-platform/proxmox.nix for why these have to be in
  # the IMAGE and not only in the module that a deploy installs.
, substituters ? []
, trustedPublicKeys ? []
}:

# Wraps `nix/images/by-platform/proxmox.nix` (type=lxc) so the resulting
# tarball lives at a stable, named path. terranix' mkFile then references
# `preparedNixosLxcTemplatePath` and the bpg/proxmox provider SCPs the
# tarball up to PVE's `local:vztmpl/` on apply — same pattern as the
# prepared Debian cloud image (nix/images/debian-cloud).
#
# Without this wrapper, the generated file has a version-suffixed
# filename (e.g. `nixos-image-lxc-proxmox-26.11pre-git-...tar.xz`)
# that would change every build and break terraform state diffing.

let
  imageOutput = import ../../images/by-platform/proxmox.nix {
    inherit pkgs sshPubKey substituters trustedPublicKeys;
    type = "lxc";
  };
in
pkgs.runCommand "nixos-lxc-template" { } ''
  mkdir -p $out
  cp ${imageOutput}/tarball/*.tar.xz $out/nixos-lxc-template.tar.xz
''
