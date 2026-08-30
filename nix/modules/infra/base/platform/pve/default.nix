{ ... }:

# PVE substrate — composes lxc + qemu variant configs. Both are imported
# unconditionally (Nix can't gate `imports` on config). The variant
# branch fires via mkIf on infra.platform.type inside each file.

{
  imports = [
    ./lxc.nix
    ./qemu.nix
  ];
}
