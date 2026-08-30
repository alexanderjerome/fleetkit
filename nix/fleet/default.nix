{ config, lib, ... }:

# Unified Proxmox/XCP-ng fleet manifest — schema v2 (SKRYBITDEV-599).
#
# Single source of truth for:
#   1. tf emitters in nix/tf/        (TF JSON per-leaf-stack)
#   2. NixOS/Colmena per-host config (via mkHosts in nix/lib/nixos.nix)
#
# Philosophy: env / stack / provider_instance / kind are PER-RESOURCE
# attributes. No structural env→provider binding. One tfstate per
# leaf (env, stack) pair. See docs/plans/unified-swinging-orbit.md.

let
  inherit (lib) attrValues attrNames filter length mapAttrs mapAttrsToList
                elem intersectLists groupBy filterAttrs throwIf
                concatStringsSep hasAttrByPath optionalAttrs;

  # Validator runs below; all attributes from providers/fleet/resources
  # must already be merged when this evaluates.
  cfg = config.fleet;

  # `enabled = false` entries are filtered out before validation and
  # emission so they behave like commented-out declarations. The flag
  # is currently compute-only (resources have no lifecycle to gate);
  # extend to resources if a similar "declared but not realised" need
  # ever appears there.
  enabledCompute = filterAttrs (_: e: e.enabled or true) cfg.compute;

  # `provisioning = "external"` entries (INFRA-170 / ADR-080) are
  # NixOS-managed only: they stay in hostsJson (Colmena target, sk
  # remote/inventory) but never reach the Terraform emitters or the
  # provider-coupled validators — their machine lives outside this
  # repo's providers.
  provisionedCompute = filterAttrs (_: e: (e.provisioning or "managed") == "managed") enabledCompute;

  # Union of tofu-provisioned compute + resources — for the stack
  # emitters and every validator that assumes a fleet.providers entry.
  allEntries = (attrValues provisionedCompute) ++ (attrValues cfg.resources);
  entriesByName = enabledCompute // cfg.resources;

  # ── Derived: fleet.stacks ───────────────────────────────────────
  # Flat map { "${env}.${stack}" = [ entry ... ]; } — consumed by
  # nix/tf/default.nix to emit one terranixConfiguration per leaf.
  stacksById = groupBy (e: "${e.env}.${e.stack}") allEntries;

  # ── Validator helpers ──────────────────────────────────────────
  # 1. Unique vm_id within (provider_instance, kind) — NOT global.
  computeGroups = groupBy (e: "${e.provider_instance}/${e.kind}")
    (filter (e: e ? vm_id) (attrValues enabledCompute));
  duplicateVmIds = lib.concatMap (group:
    let
      byVmid = groupBy (e: toString e.vm_id) group;
      dupes = filterAttrs (_: xs: length xs > 1) byVmid;
    in
      mapAttrsToList (vmid: xs:
        "${builtins.head xs}.provider_instance=${(builtins.head xs).provider_instance} vm_id=${vmid} used by ${toString (length xs)} resources"
      ) dupes
  ) (attrValues (groupBy (e: "${e.provider_instance}/${e.kind}") (filter (e: e ? vm_id) (attrValues cfg.compute))));

  # Rebuild clearly: for each (pi, kind) group, find duplicate vm_ids
  # (across enabled entries only — disabled entries are filtered above).
  computeKeyed = lib.mapAttrs (_: group:
    filterAttrs (_: xs: length xs > 1) (groupBy (e: toString e.vm_id) group)
  ) computeGroups;
  vmidViolations = lib.flatten (mapAttrsToList (groupKey: dupes:
    mapAttrsToList (vmid: entries:
      "vm_id=${vmid} in ${groupKey} used by: ${concatStringsSep ", " (map (e: builtins.head (attrNames (filterAttrs (_: v: v == e) entriesByName))) entries)}"
    ) dupes
  ) computeKeyed);

  # 2. Stateful-tag → protect OR provider_instance has destruction_policy=strict.
  providerPolicy = pi:
    let
      parts = lib.strings.splitString "." pi;
      provider = builtins.elemAt parts 0;
      instance = builtins.elemAt parts 1;
    in
      cfg.providers.${provider}.${instance}.destruction_policy or "standard";

  statefulViolations = filter
    (e:
      let
        tags = e.tags or [];
        hits = intersectLists tags cfg.STATEFUL_TAGS;
        policy = providerPolicy e.provider_instance;
      in
        hits != [] && !(e.protect or false) && policy != "strict"
    )
    allEntries;

  # 3. provider_instance must exist in fleet.providers.
  providerRefViolations = filter
    (e:
      let
        parts = lib.strings.splitString "." e.provider_instance;
        provider = builtins.elemAt parts 0;
        instance = if length parts >= 2 then builtins.elemAt parts 1 else "";
      in
        !(hasAttrByPath [ provider instance ] cfg.providers)
    )
    allEntries;

  # 4. compute.pool must match a declared fleet.resources pool entry's
  # pool_id (scoped to the same provider_instance — pools are per-PVE).
  declaredPools = lib.unique (mapAttrsToList
    (_: r: "${r.provider_instance}/${r.pool_id}")
    (filterAttrs (_: r: r.kind == "pool") cfg.resources));
  poolRefViolations = filter
    (e: e.pool != null
        && !(elem "${e.provider_instance}/${e.pool}" declaredPools))
    (attrValues provisionedCompute);

  # 5. Multi-node PVE clusters require explicit `node` on every
  #    resource that lands on a specific member. bpg/proxmox takes
  #    node_name on every container/VM/bridge/file/etc. — without it
  #    the resource would silently land on the provider's primary,
  #    which is rarely what you want when there are 5 members.
  #
  #    Cluster-wide kinds (pool, acl, realm, cluster-options) skip
  #    this — bpg doesn't take node_name for them.
  nodeScopedResourceKinds = [ "bridge" "file" "download" "dns" ];

  isProxmoxMultiNode = pi:
    let
      parts = lib.strings.splitString "." pi;
      provider = builtins.elemAt parts 0;
      instance = if length parts >= 2 then builtins.elemAt parts 1 else "";
      providerCfg = (cfg.providers.${provider} or {}).${instance} or null;
    in
      provider == "proxmox"
      && providerCfg != null
      && length (providerCfg.cluster.nodes or []) > 1;

  computeNodeViolations = filter
    (e: isProxmoxMultiNode e.provider_instance && (e.node or "") == "")
    (attrValues provisionedCompute);

  resourceNodeViolations = filter
    (e: elem e.kind nodeScopedResourceKinds
        && isProxmoxMultiNode e.provider_instance
        && (e.node or "") == "")
    (attrValues cfg.resources);

  # ── Throw chain ────────────────────────────────────────────────
  validated =
    throwIf (vmidViolations != [])
      ''
        FLEET vm_id uniqueness violations (scope: provider_instance + kind):
          ${concatStringsSep "\n  " vmidViolations}
      '' (
    throwIf (statefulViolations != [])
      ''
        FLEET stateful-tag violations (tagged resource without protect=true
        and provider_instance.destruction_policy != "strict"):
          ${concatStringsSep ", " (map (e:
            let
              name = builtins.head (attrNames (filterAttrs (_: v: v == e) entriesByName));
              hits = intersectLists (e.tags or []) cfg.STATEFUL_TAGS;
            in "${name} (tags: ${toString hits})"
          ) statefulViolations)}
      '' (
    throwIf (providerRefViolations != [])
      ''
        FLEET entries reference undefined provider_instance:
          ${concatStringsSep ", " (map (e: e.provider_instance) providerRefViolations)}
      '' (
    throwIf (poolRefViolations != [])
      ''
        FLEET compute entries reference undeclared pool:
          ${concatStringsSep ", " (map (e:
            let
              name = builtins.head (attrNames (filterAttrs (_: v: v == e) entriesByName));
            in "${name} (provider_instance=${e.provider_instance}, pool=${e.pool})"
          ) poolRefViolations)}
        Declare a `kind = "pool"` entry in fleet.resources with matching
        pool_id and provider_instance.
      '' (
    throwIf ((computeNodeViolations ++ resourceNodeViolations) != [])
      ''
        FLEET multi-node cluster targeting violations:
          ${concatStringsSep "\n  " (map (e:
            let
              name = builtins.head (attrNames (filterAttrs (_: v: v == e) entriesByName));
            in "${name} (provider_instance=${e.provider_instance}, kind=${e.kind})"
          ) (computeNodeViolations ++ resourceNodeViolations))}
        Set `node = "<member>"` on each. Available members for
        each provider:
          ${concatStringsSep "\n  " (mapAttrsToList (p: instances:
            concatStringsSep "\n    " (mapAttrsToList (i: c:
              "${p}.${i}: [ ${concatStringsSep " " (c.cluster.nodes or [])} ]"
            ) instances)
          ) cfg.providers)}
      ''
    true))));

in {
  imports = [
    # Per-concept folders — each default.nix declares schema (+ derivation
    # if any) and `imports = [ ./inputs.nix ]` pulls in the values sibling.
    ./network
    ./providers
    ./users                  # fleet.access schema (identity registry is consumer data)
    ./dns                    # fleet.dnsRecords derivation
    ./settings.nix           # fleetkit parameter surface (consumer-supplied values)

    # Flat schemas (values come from nix/hosts/**/, no separable inputs file)
    ./compute.nix
    ./resources.nix
    ./hosts-registry.nix
  ];

  options.fleet = {
    STATEFUL_TAGS = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "bitcoin" "indexer" "postgres" "timescaledb"
        "supabase" "messaging" "auth" "backup" "storage"
      ];
      description = "Tags whose presence forces protect=true (enforced by validator).";
    };

    # Derived exports — read by terranix + mkHosts.
    stacks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.attrs);
      default = {};
      internal = true;
      description = ''
        Derived attrset keyed by "ENV.STACK". Consumed by
        nix/tf/default.nix to emit one terranixConfiguration
        per leaf.
      '';
    };

    # Legacy hosts.json-shaped export — keeps mkHosts / sk launcher /
    # grafana-stack / sssd working during the transition. Built from
    # fleet.compute so there's only one source of truth.
    hostsJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {};
      internal = true;
      description = ''
        { name → { hostname, vmid, ip, internal_ip, tags, pve_type,
                   cluster?, node_index? } } — serialised to
        .cache/fleet/hosts.json by `fleet inventory generate`, consumed by the
        NixOS side (hosts.nix) and by Colmena's deploy targeting.
      '';
    };

    _meta.validated = lib.mkOption {
      type = lib.types.bool;
      default = validated;
      internal = true;
      description = "Sentinel forcing validator evaluation during nix build.";
    };
  };

  config.fleet.stacks = stacksById;

  # hostsJson reflects only enabled entries — disabled installers
  # shouldn't pollute the inventory, get Colmena targets, or appear
  # in `sk inventory`.
  config.fleet.hostsJson = mapAttrs (name: meta: {
    hostname = name;
    vmid = meta.vm_id;
    ip = meta.ip;
    internal_ip = meta.internal_ip;
    tags = meta.tags or [];
    # Despite the field name (kept for hosts.json compatibility),
    # this is the substrate-aware platform tag consumed by the
    # `infra.platform.type` option declared in
    # nix/modules/infra/base/platform/default.nix. Three values today:
    #   "pve.lxc"   — PVE-hosted LXC container (kind = "container")
    #   "pve.qemu"  — PVE-hosted KVM/QEMU VM (kind = "vm" on proxmox.*)
    #   "xcpng.vm"  — XCP-ng-hosted Xen HVM VM (kind = "vm" on
    #                 xen-orchestra.*)
    # The substrate split matters because PVE-VM and XCP-ng-VM need
    # very different boot loaders, kernel modules, and console
    # configs — see nix/modules/infra/base/platform/{pve,xcpng}/*.nix.
    pve_type =
      if meta.kind == "container" then "pve.lxc"
      else if lib.hasPrefix "xen-orchestra." meta.provider_instance then "xcpng.vm"
      else "pve.qemu";
    # Needed by `sk inventory generate` to know which entries should
    # be IP-discovered via XOA vs. PVE. The Proxmox path also benefits
    # from this for future multi-provider drift detection.
    provider_instance = meta.provider_instance;
    # Non-null for non-NixOS guests (Debian LXCs/VMs booted from an
    # explicit image). `fleet ansible inventory` uses it to place such
    # containers into the debian_guests group; NixOS guests (image ==
    # null) land in the nixos group instead.
    image = meta.image or null;
    # "managed" | "external" — external hosts (INFRA-170 / ADR-080) are
    # Colmena-deployable but must be skipped by consumers that assume
    # fleet-network reachability (CoreDNS records, hypervisor drift).
    provisioning = meta.provisioning or "managed";
    pool = meta.pool or null;
    ssh_groups = meta.ssh_groups or [ "platform-admins" ];
    sudo_groups = meta.sudo_groups or [];
  }) enabledCompute;
}
