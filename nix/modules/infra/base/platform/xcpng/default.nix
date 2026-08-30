{ ... }:

# XCP-ng substrate — Xen HVM VMs on an XCP-ng / XOA host. Only one
# variant today (full VM); leaves room for future xcpng.lxc-equivalent
# or xcpng.pv variants without restructuring.

{
  imports = [
    ./vm.nix
  ];
}
