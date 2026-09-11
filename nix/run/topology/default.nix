# nix/run/topology/ — operator/CI tooling to generate topology charts.
#
# This is runtime tooling (run standalone or in CI), not a host module — it
# lives under nix/run alongside the other `nix run .#<cmd>` utilities.
#
# Sources (no NixOS eval, no flake inputs, no token):
#   combined.nix   manifest ⊕ live inventory  → the node graph
#   substrate.nix  XCP-ng capacity card (live xo.json)
#   edge.nix       non-NixOS edge: internet / UDM / XCP-ng + networks
#   profiles.nix   render profiles (focused host subsets → their own SVGs)
#
# Commands:
#   nix run   .#regen-topology-svg     # all maps → docs/topology/svg/
#   nix build .#topology-<profile>     # render one map selectively
#   nix build .#topology-{combined,substrate}
#
# The inventory snapshot (inventory/snapshot/) is refreshed by
# `nix run .#inventory-dump` + copy raw→snapshot. It is an estate artifact and
# is not committed here, so every command below is gated on its presence — see
# `haveInventory`.

{ pkgs, lib, nix-topology, fleetCompute }:

let
  inherit (lib)
    mapAttrs mapAttrs' mapAttrsToList nameValuePair filterAttrs attrNames
    filter unique elem concatMapStringsSep concatStringsSep length;

  topoPkgs = pkgs.extend nix-topology.overlays.default;
  mkEval = mod: import nix-topology { pkgs = topoPkgs; modules = [ mod ]; };

  # Where combined.nix and substrate.nix read the live dumps from. Bound once
  # here and passed down so the existence gate below and the readFile calls it
  # guards cannot drift apart.
  inventoryDir = ../../../inventory/snapshot;

  # The snapshot is a per-estate artifact refreshed out of band (`nix run
  # .#inventory-dump`, then raw/ -> snapshot/): it is deliberately not committed
  # to fleetkit, and a Proxmox-only estate has no xo.json to dump in the first
  # place. Absent it, the two evals throw inside readFile — and because
  # `nix flake check` EVALUATES every `packages.*` output while only BUILDING
  # `checks.*`, that throw took the acceptance gate red for every consumer of
  # this flake, including ones that never wanted a topology chart. So gate it.
  # The package names stay stable either way; without a snapshot they are stubs
  # that fail at build time saying what is missing.
  haveInventory =
    builtins.pathExists (inventoryDir + "/xo.json")
    && builtins.pathExists (inventoryDir + "/pve.json");

  noInventoryMsg =
    "no inventory snapshot: expected xo.json and pve.json under inventory/snapshot/. "
    + "Refresh it with 'nix run .#inventory-dump' (needs XOA_URL/XOA_TOKEN and "
    + "PVE_ENDPOINT/PVE_TOKEN) and copy inventory/raw/ over inventory/snapshot/.";

  needsInventory = name: pkgs.runCommand name { } ''
    echo "${name}: ${noInventoryMsg}" >&2
    exit 1
  '';

  combinedNodes = (import ./combined.nix {
    inherit lib inventoryDir;
    compute = fleetCompute;
  }).nodes;
  profiles = import ./profiles.nix { inherit lib; };

  # Keep a selected node's ancestor chain (its PVE node + the XCP-ng host)
  # so the nesting survives profile filtering.
  parentOf = n: combinedNodes.${n}.parent or null;
  withAncestors = names:
    let ps  = filter (x: x != null) (map parentOf names);
        gps = filter (x: x != null) (map parentOf ps);
    in unique (names ++ ps ++ gps ++ [ "xcpng" ]);

  profileEval = p:
    let keep = withAncestors (filter (n: p.hosts n) (attrNames combinedNodes));
    in mkEval {
      imports = [ ./edge.nix ];
      nodes = filterAttrs (n: _: elem n keep) combinedNodes;
    };
  profileEvals = mapAttrs (_: profileEval) profiles;

  combinedEval  = mkEval { imports = [ ./edge.nix ]; nodes = combinedNodes; };
  substrateEval = mkEval (import ./substrate.nix { inherit lib inventoryDir; });

  svgOutDir = "docs/topology/svg";
  copyProfile = name: p:
    let out = profileEvals.${name}.config.output;
        multi = length p.views > 1;
        dst = view: if multi then "${name}-${view}.svg" else "${name}.svg";
    in concatMapStringsSep "\n"
      (view: ''cp -f --no-preserve=mode ${out}/${view}.svg "$out"/${dst view}'')
      p.views;

  regen-topology-svg = pkgs.writeShellApplication {
    name = "regen-topology-svg";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      out="${svgOutDir}"
      mkdir -p "$out"
      cp -f --no-preserve=mode ${substrateEval.config.output}/main.svg "$out"/substrate.svg
      cp -f --no-preserve=mode ${combinedEval.config.output}/main.svg "$out"/combined.svg
      ${concatStringsSep "\n" (mapAttrsToList copyProfile profiles)}
      echo "regen-topology-svg: wrote $(find "$out" -maxdepth 1 -name '*.svg' | wc -l) SVG(s) -> $out"
    '';
  };

  # PLACEHOLDER — Confluence sync via mark. Not configured yet (INFRA-26).
  confluence-sync = pkgs.writeShellApplication {
    name = "confluence-sync";
    runtimeInputs = [ pkgs.mark ];
    text = ''
      echo "confluence-sync: not configured yet — see the INFRA-26 sub-task." >&2
      echo "mark is available in PATH: $(command -v mark)" >&2
      exit 1
    '';
  };
in
# Same attribute names on both branches — a consumer's `packages` set does not
# change shape depending on whether it happens to have a snapshot on disk.
if haveInventory then
  {
    inherit regen-topology-svg confluence-sync;
    topology-combined = combinedEval.config.output;
    topology-substrate = substrateEval.config.output;
  }
  // mapAttrs' (n: e: nameValuePair "topology-${n}" e.config.output) profileEvals
else
  {
    inherit confluence-sync;
    # Still a real script rather than a failing build, so `nix run` reports the
    # missing snapshot instead of a Nix error about a path.
    regen-topology-svg = pkgs.writeShellApplication {
      name = "regen-topology-svg";
      text = ''
        echo "regen-topology-svg: ${noInventoryMsg}" >&2
        exit 1
      '';
    };
    topology-combined = needsInventory "topology-combined";
    topology-substrate = needsInventory "topology-substrate";
  }
  # Keyed off `profiles`, not `profileEvals`, for the names only: profiles.nix
  # reads no inventory, and profileEvals is derived from it, so the two branches
  # cannot disagree about which topology-<profile> attributes exist.
  // mapAttrs' (n: _: nameValuePair "topology-${n}" (needsInventory "topology-${n}")) profiles
