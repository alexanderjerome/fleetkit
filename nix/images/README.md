# nix/images

Bootable image and installer builds — everything needed to get a blank
machine to the point where Colmena/terranix take over.

- `bootstrap.nix` — minimal NixOS LXC tarball for Proxmox: boots, DHCPs
  on eth0, accepts SSH; all real config arrives via Colmena afterwards.
- `lxc-template/` — the productionized LXC template build.
- `debian-cloud/` — Debian cloud image preparation (for non-NixOS guests).
- `by-platform/` — installer/template images per hypervisor platform
  (Proxmox, XCP-ng / Xen Orchestra installers).

Outputs are uploaded to the hypervisor as templates that
`nix/tf/compute` provisions containers/VMs from.
