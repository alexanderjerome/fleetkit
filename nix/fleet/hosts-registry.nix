{ lib, ... }:

# Per-host NixOS module dispatcher.
#
# Each entry under nix/hosts/**/<name>.nix contributes a module function
# here AND its terranix fleet.compute entry. `mkHosts` (nix/lib/) reads
# this option to assemble the Colmena/NixOS host registry.
#
# Function shape:
#   { config, lib, pkgs, helpers, ... }: { ... NixOS config ... }
#
# `helpers` is supplied via _module.args at host-eval time by mkHosts
# and carries dnsRecords / publicDnsRecords / sshGroupsOf.
#
# Hosts that are fleet-only (e.g. tier-1 PVE hosts whose OS comes from
# the PVE installer, not Colmena) simply omit this entry. Auto-discovery
# in nix/hosts/default.nix walks the tree regardless.

{
  options.fleet.hostsRegistry = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    default = {};
    example = lib.literalExpression ''
      {
        app-db = { config, pkgs, helpers, ... }: {
          infra.data.postgresql.enable = true;
        };
      }
    '';
    description = ''
      { hostName -> NixOS module function }. Consumed by
      nix/lib/default.nix mkHosts. Populated by each host file under
      nix/hosts/**/.
    '';
  };
}
