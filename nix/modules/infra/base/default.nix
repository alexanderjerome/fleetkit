# Always-on foundation of the `infra` module.
#
# core/            "any NixOS host with the right substrate could boot
#                  from this" — users, ssh, locale UTC, single-DHCP
#                  eth0, nix gc. Transitively imports ./platform for
#                  substrate-specific boot/kernel config.
# fleet-member.nix "fleet member" — talks to fleet DNS, trusts the
#                  fleet CA, ships logs to fleet observability.
#                  Bootstrap templates intentionally skip this layer.
{ ... }:
{
  imports = [
    ./core
    ./fleet-member.nix
  ];
}
