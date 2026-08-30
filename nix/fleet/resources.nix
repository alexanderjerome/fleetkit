{ lib, ... }:

# Schema for fleet.resources — non-OS-carrying primitives (bridges,
# pools, ACLs, DNS, file uploads, XO data sources, Cloudflare zones).
#
# SKRYBITDEV-628 refactor: this file holds ONLY the schema. Entries
# moved to:
#   - nix/hosts/xoa/resources.nix          — XO pool, networks, SRs, templates
#   - nix/hosts/pve/resources.nix   — proxmox.dev pools / ACLs /
#                                            bridges / DNS / files / snippets
#   - nix/fleet/dns/inputs.nix                    — Cloudflare zone (cross-cutting)
#
# Discriminated-union style: the submodule accepts arbitrary extra
# attrs (for kind-specific fields) but requires the common four.
# Validation of kind-specific shapes happens in the emitter.

let
  resourceType = lib.types.submodule ({ name, ... }: {
    freeformType = lib.types.attrs;
    options = {
      env = lib.mkOption { type = lib.types.str; };
      stack = lib.mkOption { type = lib.types.str; };
      provider_instance = lib.mkOption {
        type = lib.types.strMatching "^[a-z-]+\\.[a-z][a-z0-9-]*$";
      };
      kind = lib.mkOption {
        type = lib.types.enum [
          # Proxmox
          "bridge" "pool" "group" "acl" "realm" "dns" "download" "file" "cluster-options"
          "metrics-server"
          # Xen-Orchestra (data-source only)
          "xo-pool" "xo-network" "xo-sr" "xo-template" "xo-iso"
          # Cloudflare
          "cloudflare-zone"
          # Grafana Cloud (INFRA-144) — synthetic monitoring + alerting
          "sm-check" "grafana-contact-point" "grafana-message-template"
          "grafana-folder" "grafana-rule-group"
        ];
      };
      protect = lib.mkOption { type = lib.types.bool; default = false; };
      notes = lib.mkOption { type = lib.types.str; default = ""; };

      # PVE cluster-member targeting for node-scoped kinds (bridge,
      # file, download, dns). Cluster-wide kinds (pool, acl, realm,
      # cluster-options, cloudflare-zone, xo-*) ignore this. Same
      # semantics as fleet.compute.<name>.node: empty defaults to
      # provider's cluster.primary_node.
      node = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "PVE cluster member name for node-scoped resources. Empty = cluster.primary_node.";
      };
    };
  });
in {
  options.fleet.resources = lib.mkOption {
    type = lib.types.attrsOf resourceType;
    default = {};
    description = "Non-OS resources across all providers. Entries live in nix/hosts/**/resources/ and nix/fleet/dns/inputs.nix.";
  };
}
