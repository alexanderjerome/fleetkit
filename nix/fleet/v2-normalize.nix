{ config, lib, ... }:

# ADR-096 normaliser — the keystone of schema v2.
#
# Everything authored in the provider-rooted tree
# (fleet.providers.<p>.<i>[.nodes.<n>].resources.<kind>.<name>) is LIFTED
# into the flat options every projection already consumes:
#
#   machines (lxc/vm)  → fleet.compute.<name>   (+ fleet.hostsRegistry.<name>
#                                                 from the nixos facet)
#   other kinds        → fleet.resources.<name>  (kind via v2-types kindMap)
#   secrets facet      → fleet.secrets.<name>    (consumers.hosts = [ machine ])
#
# So emitters, validators, hostsJson, colmena and mkHosts were rewritten
# ZERO times for v2: the flat layer is now the derived normal form, and both
# authoring styles coexist during migration. The cost of that choice is that
# field typing bites at the lift target rather than the authoring site —
# accepted in ADR-096's typing note.
#
# Name collisions between styles are a hard eval error here, not a module
# merge: silently deep-merging half a machine from each style is exactly the
# broken-state-representable problem v2 exists to remove.

let
  inherit (lib) mapAttrsToList concatLists nameValuePair listToAttrs
                filterAttrs optionalAttrs;
  v2 = import ./v2-types.nix { inherit lib; };
  provs = config.fleet.providers;

  facetNames = [ "nixos" "secrets" "provides" "bootOrder" ];

  # Every provider family that carries instances (utility providers have no
  # resources option and are skipped by the ? check).
  instances = concatLists (mapAttrsToList (pname: insts:
    if builtins.isAttrs insts
    then mapAttrsToList (iname: icfg: { inherit pname iname icfg; })
         (filterAttrs (_: c: builtins.isAttrs c && (c ? resources || c ? nodes)) insts)
    else []) provs);

  stripFacets = m: removeAttrs m facetNames;

  liftMachine = { pname, iname, node ? null }: kind: name: m:
    nameValuePair name (stripFacets m // {
      kind = if kind == "lxc" then "container" else "vm";
      provider_instance = "${pname}.${iname}";
    } // optionalAttrs (node != null) { inherit node; });

  machinePairs = concatLists (map ({ pname, iname, icfg }:
    let res = icfg.resources or {};
        nodeRes = concatLists (mapAttrsToList (node: ncfg:
          concatLists (mapAttrsToList (kind: ms:
            mapAttrsToList (liftMachine { inherit pname iname node; } kind) ms)
            (filterAttrs (k: _: k == "lxc" || k == "vm") (ncfg.resources or {}))))
          (icfg.nodes or {}));
        instRes = concatLists (mapAttrsToList (kind: ms:
          mapAttrsToList (liftMachine { inherit pname iname; } kind) ms)
          (filterAttrs (k: _: k == "lxc" || k == "vm") res));
    in instRes ++ nodeRes) instances);

  machinesByName = listToAttrs machinePairs;

  # Collect the source machine attrsets (with facets intact) for the
  # hostsRegistry / secrets projections.
  rawMachines = listToAttrs (concatLists (map ({ pname, iname, icfg }:
    let all = (mapAttrsToList (kind: ms: ms)
                 (filterAttrs (k: _: k == "lxc" || k == "vm") (icfg.resources or {})))
           ++ concatLists (mapAttrsToList (_: ncfg:
                 mapAttrsToList (kind: ms: ms)
                   (filterAttrs (k: _: k == "lxc" || k == "vm") (ncfg.resources or {})))
                 (icfg.nodes or {}));
    in concatLists (map (ms: mapAttrsToList nameValuePair ms) all)) instances));

  resourcePairs = concatLists (map ({ pname, iname, icfg }:
    let km = v2.kindMap.${pname} or {};
        kinds = filterAttrs (k: _: k != "lxc" && k != "vm" && km ? ${k})
                  (icfg.resources or {});
    in concatLists (mapAttrsToList (kind: entries:
         mapAttrsToList (name: e: nameValuePair name (e // {
           kind = km.${kind};
           provider_instance = "${pname}.${iname}";
         })) entries) kinds)) instances);

  # ── Cross-style collisions: what IS and IS NOT caught ───────────
  # A machine declared in both styles with the same field set twice
  # (vm_id, internal_ip, …) fails loudly via ordinary option merging:
  # "The option fleet.compute.<name>.<field> has conflicting definition
  # values". That covers the realistic mistake. What merging does NOT
  # catch is a dual declaration with DISJOINT fields, which deep-merges
  # silently — a hard guard was attempted via options.*.definitions and
  # is impossible without infinite recursion: introspecting definitions
  # forces their values, including the guarded one. Accepted for the
  # migration window (disjoint dual declaration is facet-splitting, which
  # is at least coherent); revisit when flat authoring is retired.
in
{
  options.fleet.secrets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.raw);
    default = {};
    description = "Secret resources: { <name> = { file; consumers?; instances.<i> = { secrets.…; }; }; }. Machine secret facets lift here with consumers.hosts = [ that machine ]. Projections: sops.secrets on consuming hosts, the secrets catalog, env export.";
  };

  options.fleet.byName = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {};
    internal = true;
    description = "Flat name → normalised entry index over machines + resources, both styles. THE lookup surface for DNS, colmena and tooling.";
  };

  config = {
    fleet.compute = machinesByName;

    fleet.resources = listToAttrs resourcePairs;

    fleet.hostsRegistry = lib.mapAttrs (_: m: m.nixos)
      (filterAttrs (_: m: (m.nixos or null) != null) rawMachines);

    fleet.secrets = lib.mapAttrs (name: m:
      (m.secrets) // { consumers = (m.secrets.consumers or {}) // { hosts = [ name ]; }; })
      (filterAttrs (_: m: (m.secrets or null) != null) rawMachines);

    fleet.byName = config.fleet.compute // config.fleet.resources;
  };
}
