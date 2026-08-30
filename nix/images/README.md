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

## Why these are not flake `packages`

The builders are deliberately **not** exposed as top-level flake packages:
they only make sense with consumer inputs (an SSH public key at minimum),
and a bare `nix build` of a keyless image is a foot-gun. Import them as
functions from your consumer flake instead:

```nix
packages.x86_64-linux.my-xcpng-template =
  import fleetkit/nix/images/by-platform/xen-orchestra.nix {
    inherit nixpkgs;
    system = "x86_64-linux";
    sshPubKey = "ssh-ed25519 AAAA… ops@example.com";
  };
```

Fleets that enable `infra.builder.lxcTemplateFactory` never build images by
hand — the module consumes the Proxmox builder directly, passing
`fleet.network.sysadmin_ssh_key`.
