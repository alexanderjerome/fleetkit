# nix/run/topology/edge.nix — the upstream edge (INFRA-25).
#
# Declares the pieces that are NOT in the hypervisor dumps: the internet,
# the edge router, and the lab/wan/fleet networks. The hypervisor host
# itself comes from combined.nix / substrate.nix (live data) — here we only
# attach its lab-side leg so the router ↔ hypervisor cable has a landing
# interface.
#
# EXAMPLE VALUES: the addresses below are documentation values (RFC 5737).
# Replace them with your own edge topology in the consumer repo.

{ config, lib, ... }:

let
  inherit (config.lib.topology) mkConnection;
in
{
  networks.wan = {
    name = "WAN · internet";
    cidrv4 = "0.0.0.0/0";
  };
  networks.lab = {
    name = "lab LAN · 192.0.2.0/24";
    cidrv4 = "192.0.2.0/24";
  };
  networks.fleet = {
    name = "fleet · 198.51.100.0/24";
    cidrv4 = "198.51.100.0/24";
  };

  nodes.internet = {
    name = "internet";
    deviceType = "internet";
    interfaces.uplink = { network = "wan"; };
  };

  nodes.edge-router = {
    name = "edge router";
    deviceType = "router";
    hardware.info = "edge router — 2× public WAN";
    interfaces.wan1 = { network = "wan"; addresses = [ "203.0.113.10" ];
                        physicalConnections = [ (mkConnection "internet" "uplink") ]; };
    interfaces.wan2 = { network = "wan"; addresses = [ "203.0.113.11" ];
                        physicalConnections = [ (mkConnection "internet" "uplink") ]; };
    interfaces.lan  = { network = "lab"; addresses = [ "192.0.2.1" ]; };
  };

  # xcpng's name/specs come from combined.nix (live). Only add the lab leg
  # so the router cable lands somewhere — module-merges with the combined node.
  nodes.xcpng.interfaces.eth2 = {
    network = "lab";
    addresses = [ "192.0.2.127" ];
    physicalConnections = [ (mkConnection "edge-router" "lan") ];
  };
}
