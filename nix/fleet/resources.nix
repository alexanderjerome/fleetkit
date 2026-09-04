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
      env = lib.mkOption {
        type = lib.types.str;
        example = "infra";
        description = "Logical env (infra / platform / dev / prod / ...). Together with `stack` forms the leaf stack id `<env>.<stack>`.";
      };
      stack = lib.mkOption {
        type = lib.types.str;
        example = "core";
        description = "Dot-path stack label within env (e.g. \"core\", \"bitcoin.mainnet\"). Selects which `fleet tf` leaf stack emits this resource.";
      };
      provider_instance = lib.mkOption {
        type = lib.types.strMatching "^[a-z-]+\\.[a-z][a-z0-9-]*$";
        example = "proxmox.dev";
        description = ''Pointer to fleet.providers: "<provider>.<instance>" (e.g. "proxmox.dev"). Routes the entry to the matching provider emitter.'';
      };
      kind = lib.mkOption {
        description = "What the resource is. Selects the emitter code path and the kind-specific freeform fields it expects (validated in the emitter, not here).";
        type = lib.types.enum [
          # Proxmox
          "bridge" "pool" "group" "acl" "realm" "dns" "download" "file" "cluster-options"
          "metrics-server"
          # Proxmox SDN (zone → vnet → subnet; an applier is emitted per
          # stack automatically), node VLAN interfaces, storages
          "sdn-zone" "sdn-vnet" "sdn-subnet" "linux-vlan"
          "storage-nfs" "storage-dir"
          # Xen-Orchestra (data-source only)
          "xo-pool" "xo-network" "xo-sr" "xo-template" "xo-iso"
          # Cloudflare
          "cloudflare-zone"
          # Grafana Cloud (INFRA-144) — synthetic monitoring + alerting
          "sm-check" "grafana-contact-point" "grafana-message-template"
          "grafana-folder" "grafana-rule-group"
        ];
      };
      protect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Emit `lifecycle.prevent_destroy = true` on the generated Terraform resource. The `fleet tf destroy` preflight refuses to target protected resources.";
      };
      notes = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Free-text audit note (why the resource exists, tickets, caveats). Informational only — never affects the emitted Terraform.";
      };

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
    example = lib.literalExpression ''
      {
        pool-platform = {
          env = "infra";
          stack = "core";
          provider_instance = "proxmox.dev";
          kind = "pool";
          pool_id = "platform";
          comment = "Platform-tier containers";
        };
      }
    '';
    description = "Non-OS resources across all providers. Entries live in nix/hosts/**/resources/ and nix/fleet/dns/inputs.nix.";
  };
}
