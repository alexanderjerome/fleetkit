# nix/run/topology/combined.nix — manifest ⊕ live inventory (INFRA-25 / INFRA-31).
#
# Combines the two sources of truth into one node graph:
#   * fleet manifest (fleet.compute) — SEMANTIC: what each host is (tags,
#     role, the org flake-input it runs, intended placement).
#   * inventory/snapshot/{xo,pve}.json — FACTUAL: real CPU/RAM/IP/disks,
#     power state, actual placement, and hosts the manifest doesn't track.
#
# Join key = host name (a fleet.compute attr name == an XO VM name_label ==
# a PVE guest name). Live facts win for hardware; the manifest fills what
# the API can't see (org component, declared-only hosts). A provenance badge
# makes drift visible: live+declared → power state; live-only → "untracked";
# declared-only → "declared (not live)".
#
# The JSON is the committed snapshot (inventory/snapshot/), refreshed by
# `nix run .#inventory-dump` + the regen flow. Returns { nodes = {...}; }.

{ lib, compute, inventoryDir ? ../../../inventory/snapshot,
  # Consumer-supplied mapping: host name → the org flake-input it runs
  # (manifest knowledge the hypervisor API can't see). null ⇒ no badge.
  orgOf ? (name: null) }:

let
  inherit (builtins) fromJSON readFile head filter attrValues attrNames length;
  inherit (lib)
    listToAttrs optional concatStringsSep foldl' splitString hasPrefix
    hasSuffix findFirst removePrefix unique;

  xo  = fromJSON (readFile (inventoryDir + "/xo.json"));
  pve = fromJSON (readFile (inventoryDir + "/pve.json"));
  XCPNG = "xcpng";
  host  = head xo.hosts;
  toGiB = b: b / 1073741824;

  xoByName  = listToAttrs (map (v: { name = v.name_label; value = v; }) xo.vms);
  pveByName = listToAttrs (map (g: { name = g.resource.name; value = g; }) (attrValues pve.guests));

  # IP is embedded in the PVE net0 string: "...,ip=192.0.2.112/24,...".
  net0Ip = net0:
    let p = findFirst (x: hasPrefix "ip=" x) null (splitString "," net0);
    in if p == null then "" else removePrefix "ip=" p;

  allNames = unique (attrNames compute ++ attrNames xoByName ++ attrNames pveByName);

  mergeNode = name:
    let
      decl = compute.${name} or null;
      xov  = xoByName.${name} or null;
      pveg = pveByName.${name} or null;

      liveVcpu   = if pveg != null then (pveg.config.cores or 0)
                   else if xov != null then (xov.CPUs.number or 0) else null;
      liveMemGiB = if pveg != null then ((pveg.config.memory or 0) / 1024)
                   else if xov != null then (toGiB (xov.memory.size or 0)) else null;
      liveIp     = if pveg != null then net0Ip (pveg.config.net0 or "")
                   else if xov != null then (xov.mainIpAddress or "") else "";
      power      = if xov != null then xov.power_state
                   else if pveg != null then (pveg.resource.status or "?") else null;

      declVcpu   = if decl != null then (decl.cpu_cores or 0) else 0;
      declMemGiB = if decl != null then ((decl.memory_mb or 0) / 1024) else 0;
      declIp     = if decl != null then
                     (if (decl.internal_ip or "") != "" then decl.internal_ip else (decl.ip or ""))
                   else "";

      vcpu   = if liveVcpu != null then liveVcpu else declVcpu;
      memGiB = if liveMemGiB != null then liveMemGiB else declMemGiB;
      ip     = if (liveIp != null && liveIp != "") then liveIp else declIp;

      present = decl != null;
      isLive  = (xov != null) || (pveg != null);
      badge   = if !present then "untracked"
                else if !isLive then "declared (not live)"
                else if power != null then power else "live";

      org = orgOf name;

      parent =
        if pveg != null then pveg.node
        else if xov != null then XCPNG
        else if decl != null && (decl.node or "") != "" then decl.node
        else XCPNG;

      specs = concatStringsSep " · "
        ([ "${toString vcpu} vCPU" "${toString memGiB} GiB" ] ++ optional (ip != "") ip);
    in {
      name = name;
      value = {
        name = name;
        deviceType = "device";
        parent = parent;
        guestType = specs;
        hardware.info = concatStringsSep " · "
          ([ badge ] ++ optional (org != null) org ++ [ specs ]);
      };
    };

  bodyNodes = listToAttrs (map mergeNode (filter (n: n != XCPNG) allNames));

  vms     = xo.vms;
  running = filter (v: v.power_state == "Running") vms;
  sumVcpu = foldl' (a: v: a + (v.CPUs.number or 0)) 0 vms;
  sumMem  = foldl' (a: v: a + (v.memory.size or 0)) 0 vms;
  hostNode = {
    "${XCPNG}" = {
      name = "XCP-ng · ${host.name_label}";
      deviceType = "device";
      hardware.info =
        "${host.productBrand} ${host.version} · ${host.CPUs.cpu_count} threads · "
        + "${toString (toGiB host.memory.size)} GiB · "
        + "${toString (length vms)} VMs (${toString (length running)} running) · "
        + "${toString sumVcpu} vCPU + ${toString (toGiB sumMem)} GiB reserved";
    };
  };
in
{
  nodes = hostNode // bodyNodes;
}
