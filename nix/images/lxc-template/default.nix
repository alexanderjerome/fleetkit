{ pkgs
  # Operator SSH public key baked into the template's root account —
  # fleets pass config.fleet.network.sysadmin_ssh_key.
, sshPubKey ? throw "images/lxc-template: pass sshPubKey (e.g. config.fleet.network.sysadmin_ssh_key)"
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
    inherit pkgs sshPubKey;
    type = "lxc";
  };
in
pkgs.runCommand "nixos-lxc-template" { } ''
  mkdir -p $out
  cp ${imageOutput}/tarball/*.tar.xz $out/nixos-lxc-template.tar.xz
''
