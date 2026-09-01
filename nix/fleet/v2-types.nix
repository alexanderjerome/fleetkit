{ lib }:

# ADR-096 authoring types — the provider-rooted resource tree.
#
# TYPING NOTE (deliberate deviation from ADR-096 §2, recorded there at
# acceptance): kinds are typed as PATH SEGMENTS with per-kind attrsOf
# submodules rather than lib.types.attrTag, and the machine submodule is
# freeform over its compute fields. Full field-level enforcement happens at
# the NORMALISED layer — every v2 machine lifts into fleet.compute, whose
# submodule is strictly typed, so a bad field fails eval with the same
# message it always has. Native v2 field types can tighten later without
# breaking authors; starting loose-here/strict-below made v2 shippable
# without retyping 500 lines of compute schema on day one.
let
  inherit (lib) types mkOption;

  # One machine (LXC container or VM), authored in place in the tree.
  # Freeform passthrough carries every fleet.compute field (vm_id, ips,
  # tags, mount_points, network_mode, …) — validated after the lift.
  machine = types.submodule {
    freeformType = types.attrsOf types.raw;
    options = {
      env   = mkOption { type = types.str; example = "platform"; description = "Logical environment label; with `stack` selects the leaf tf stack (\"env.stack\")."; };
      stack = mkOption { type = types.str; example = "core"; description = "Stack grouping within env."; };

      nixos = mkOption {
        type = types.nullOr types.unspecified;
        default = null;
        description = "This machine's NixOS module function ({ config, helpers, ... }: { … }). Replaces the parallel fleet.hostsRegistry entry; null = not colmena-managed (installer-provisioned, non-NixOS, …).";
      };

      secrets = mkOption {
        type = types.nullOr (types.attrsOf types.raw);
        default = null;
        description = "Secret declaration facet ({ file; instances.<name> = { secrets.…; envPrefix?; … }; }). Instances declared here are implicitly consumed by THIS machine; shared/host-less secrets belong in fleet.secrets instead.";
      };

      provides = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "proxmox.skrybit-pve";
        description = "This machine IS a member of the named provider instance — the recursive estate link (a PVE node that is itself an XO VM). Drives derived defaults (hypervisor scrape targets) and makes the layer dependency queryable.";
      };

      bootOrder = mkOption {
        type = types.nullOr (types.enum [ "cnd" "dnc" ]);
        default = null;
        description = "XO VMs: explicit boot order (c=disk n=network d=dvd). null = derived from tags (transient ⇒ dnc). Replaces the tag heuristic as the authored form; emitted via the post-create fix hook either way.";
      };
    };
  };

  machines = types.attrsOf machine;

  # Instance-scoped (non-machine) resources: loose per-kind maps, same
  # strictness rationale as above — the lift targets fleet.resources whose
  # validators (stateful tags, provider refs, node targeting) still run.
  looseKind = types.attrsOf (types.attrsOf types.raw);
  kindOpt = desc: mkOption { type = looseKind; default = {}; description = desc; };
in
{
  inherit machine machines kindOpt looseKind;

  nodeType = types.submodule {
    options = {
      mgmt_ip = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Management/API address of this hypervisor node. Feeds derived scrape targets when the node is not `provides`-linked to a fleet VM.";
      };
      resources = mkOption {
        type = types.submodule {
          options = {
            lxc = mkOption { type = machines; default = {}; description = "LXC containers placed on this node."; };
            vm  = mkOption { type = machines; default = {}; description = "KVM/QEMU VMs placed on this node."; };
          };
        };
        default = {};
        description = "Machines placed on this node.";
      };
    };
  };

  # v2 kind → legacy fleet.resources `kind` string, per provider family.
  # The lift uses this so every existing emitter keeps working unchanged.
  kindMap = {
    proxmox = {
      pool = "pool"; acl = "acl"; group = "group"; realm = "realm";
      cluster-options = "cluster-options"; metrics-server = "metrics-server";
      bridge = "bridge"; dns = "dns"; file = "file"; download = "download";
    };
    xen-orchestra = {
      iso = "xo-iso"; network = "xo-network"; pool = "xo-pool";
      sr = "xo-sr"; template = "xo-template";
    };
    cloudflare = { zone = "cloudflare-zone"; };
    grafana = {
      folder = "grafana-folder"; contact-point = "grafana-contact-point";
      message-template = "grafana-message-template";
      rule-group = "grafana-rule-group"; sm-check = "sm-check";
    };
  };
}
