# nix/run/topology/substrate.nix — XCP-ng host capacity card, from live data.
#
# The single hypervisor node rendered as a full card: OS, CPU (reserved /
# available), RAM, VM count, storage repositories (used / total / free), and
# all physical NICs. Reads the committed snapshot (inventory/snapshot/) — so
# unlike the old hand-maintained hypervisors.nix, this is always the real,
# current host. Returns a nix-topology module.

{ lib, inventoryDir ? ../../../inventory/snapshot }:

let
  inherit (builtins) fromJSON readFile head filter foldl' length;
  inherit (lib) listToAttrs optional;

  xo   = fromJSON (readFile (inventoryDir + "/xo.json"));
  host = head xo.hosts;
  toGiB = b: b / 1073741824;

  vms     = xo.vms;
  running = filter (v: v.power_state == "Running") vms;
  sumVcpu = foldl' (a: v: a + (v.CPUs.number or 0)) 0 vms;
  sumMem  = foldl' (a: v: a + (v.memory.size or 0)) 0 vms;

  realSrs = filter (s: (s.size or 0) > 0) xo.srs;
  srSvc = sr: {
    name = "${sr.name_label} (${sr.SR_type})";
    info = "${toString (toGiB (sr.physical_usage or 0))} / ${toString (toGiB sr.size)} GiB used"
         + " · ${toString (toGiB (sr.size - (sr.physical_usage or 0)))} GiB free";
  };

  nicIface = p: {
    name = p.device;
    value = {
      type = "ethernet";
      addresses = optional ((p.ip or "") != "") p.ip;
    };
  };
in
{
  nodes.xcpng = {
    name = "XCP-ng · ${host.name_label}";
    deviceType = "device";
    # deviceType "device" → a bare image+name by default; force the full card.
    renderer.preferredType = "card";
    hardware.info = "${host.productBrand} ${host.version} · ${host.CPUs.modelname or "?"}";

    interfaces = listToAttrs (map nicIface xo.pifs);

    services =
      {
        cpu = { name = "CPU"; info = "${toString sumVcpu} vCPU reserved · ${host.CPUs.cpu_count} threads available"; };
        ram = { name = "RAM"; info = "${toString (toGiB sumMem)} / ${toString (toGiB host.memory.size)} GiB reserved"; };
        vms = { name = "VMs"; info = "${toString (length vms)} total · ${toString (length running)} running"; };
      }
      // listToAttrs (map (s: { name = "sr-${s.name_label}"; value = srSvc s; }) realSrs);
  };
}
