# Prepared Debian 13 cloud image for non-NixOS VMs (ADR-013 / ADR-018).
#
# Takes the upstream Debian cloud image and bakes in EVERYTHING a fresh
# dev VM needs so first-boot is just "set hostname, create user, install
# Nix" — no ansible, no apt round-trip, no apt-cacher dependency, no
# GitHub PAT on disk.
#
# Customizations applied via virt-customize (libguestfs):
#
#   Boot reliability
#   • Mask systemd-firstboot.service via ln -sf /dev/null + systemctl
#     mask. Default Debian 13 leaves this enabled and it blocks
#     sysinit.target waiting on an interactive locale/timezone prompt.
#     Defence in depth alongside the locale/timezone pre-seed below.
#   • Truncate /etc/machine-id and rm /var/lib/dbus/machine-id so each
#     freshly cloned VM gets a unique systemd machine-id on first boot.
#   • Pre-seed timezone and a stub /etc/locale.conf.
#
#   Pre-installed packages
#   • qemu-guest-agent + enabled — lets tofu see the agent within seconds
#     of boot instead of timing out at 15 min waiting for cloud-init's
#     runcmd to apt-install it.
#   • docker.io + docker-compose-v2 + enabled.
#   • git, curl, ca-certificates, wget, gnupg2.
#   • vim, tmux, htop, jq, build-essential, zsh, unattended-upgrades.
#
#   Output ~1.0 GiB qcow2 in the Nix store; build time ~5 min on TCG,
#   ~1 min with KVM.
#
# Requires `sandbox = relaxed` in /etc/nix/nix.conf because
# `virt-customize --install` runs apt inside the appliance VM which
# needs internet. Pattern adapted from community-scripts/ProxmoxVE's
# build-vm.func.
{ lib
, runCommand
, fetchurl
, libguestfs-with-appliance
, guestfs-tools

# Pin to a specific upload so the hash stays stable. Debian periodically
# replaces the "latest" symlink with a new build — bump when the upstream
# hash drifts (build fails with "hash mismatch in fixed-output derivation").
# Get the fresh hash via:
#   nix-prefetch-url --type sha256 <imageUrl>
#   nix hash convert --to sri --hash-algo sha256 <legacy-hash>
, imageUrl ? "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
, imageHash ? "sha256-BYFqUlxMELvo//RBbp8Y4nZAzmomvIixVv3G7/T2HmI="  # re-pinned 2026-08-13 (INFRA-194)

# Packages installed via `apt-get install` inside the image. Keep this
# list lean — anything per-VM (docker daemon.json data-root, dev user
# membership) belongs in the cloud-init renderer, not here.
, aptPackages ? [
    "qemu-guest-agent"
    "docker.io"
    "docker-compose"      # compose v2 plugin is NOT part of docker.io (INFRA-194)
    "git" "curl" "wget" "ca-certificates" "gnupg2"
    "vim" "tmux" "htop" "jq"
    "build-essential"
    "zsh"
    "unattended-upgrades"
  ]
}:

let
  upstream = fetchurl {
    url = imageUrl;
    hash = imageHash;
  };
  aptList = lib.concatStringsSep "," aptPackages;
in
runCommand "debian-13-genericcloud-amd64-prepared.qcow2" {
  __noChroot = true;
  nativeBuildInputs = [ libguestfs-with-appliance guestfs-tools ];
  passthru.upstream = upstream;
  passthru.aptPackages = aptPackages;
  meta = {
    description = "fleetkit-prepared Debian 13 genericcloud image (firstboot fixes + docker/qemu-guest-agent/dev tools preinstalled).";
    license = lib.licenses.gpl2Plus;
  };
} ''
  set -euo pipefail

  # virt-customize wants a writable image; copy out of the /nix/store
  # first so we own the working file's rw bit.
  cp ${upstream} work.qcow2
  chmod u+w work.qcow2

  # supermin appliance + TCG fallback inside the Nix sandbox where
  # /dev/kvm isn't available. Without these the appliance hangs trying
  # to KVM. apt-get inside the appliance reaches the network because
  # __noChroot = true relaxes the build sandbox.
  export LIBGUESTFS_BACKEND=direct
  export TMPDIR=$PWD/tmp
  mkdir -p "$TMPDIR"
  if [ ! -e /dev/kvm ]; then
    export LIBGUESTFS_BACKEND_SETTINGS=force_tcg
  fi

  virt-customize -a work.qcow2 \
    --run-command 'ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service' \
    --run-command 'systemctl mask systemd-firstboot.service || true' \
    --run-command 'truncate -s 0 /etc/machine-id' \
    --run-command 'rm -f /var/lib/dbus/machine-id' \
    --run-command 'echo Etc/UTC > /etc/timezone' \
    --run-command 'ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime' \
    --run-command 'touch /etc/locale.conf' \
    --update \
    --install '${aptList}' \
    --run-command 'systemctl enable docker qemu-guest-agent unattended-upgrades' \
    --run-command 'apt-get clean'

  mv work.qcow2 $out
''
