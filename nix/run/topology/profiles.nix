# nix/topology/profiles.nix — topology render profiles (INFRA-25).
#
# Each profile is a FOCUSED map: a subset of hosts + which rendered view(s)
# to keep. The flake builds one nix-topology eval per profile, so each
# becomes its own decent-sized SVG for embedding in a Confluence page —
# instead of one unreadable megafile.
#
#   <name> = {
#     title;                     # Confluence page / caption
#     description;
#     hosts = <hostName -> bool>;  # which NixOS hosts to include (Lane A)
#     views = [ "network" "main" ]; # which of the two rendered SVGs to keep
#   };
#
# Add a profile = add an entry here. Build one selectively with
# `nix build .#topology-<name>`; `regen-topology-svg` writes them all.

{ lib }:

let
  inherit (lib) any hasPrefix elem;
  anyPrefix = ps: n: any (p: hasPrefix p n) ps;
  inSet = ns: n: elem n ns;
  SPINE = "netcore"; # the fleet gateway — pull into focused maps for context
in
{
  overview = {
    title = "Fleet network overview";
    description = "Whole-fleet layer-3 map: internet → UDM → netcore → fleet subnet. The index diagram.";
    hosts = _: true;
    views = [ "network" ];
  };

  platform = {
    title = "Platform & infrastructure";
    description = "Tier-0 spine + shared platform services: auth, observability, secrets, VPN, build, storage, queue.";
    hosts = inSet [
      SPINE "authentik" "auth-db" "grafana"
      "infisical" "infisical-db" "infisical-valkey"
      "vpn" "nix-builder" "s3" "rabbitmq"
    ];
    views = [ "network" "main" ];
  };

  bitcoin = {
    title = "Bitcoin nodes & indexers";
    description = "Bitcoin Core nodes (mainnet/testnet/signet) + the ord / bitcoin-indexer pipeline.";
    hosts = n: anyPrefix [ "btc-" "indexer-" "ord-" ] n || n == SPINE;
    views = [ "network" "main" ];
  };

  apps = {
    title = "Apps & databases";
    description = "Customer-facing APIs/UIs (mainnet/testnet) + the Postgres/Timescale databases backing them.";
    hosts = n: anyPrefix [ "api-" "app-" "inscribe-" "analytics" "timescale" ] n || n == SPINE;
    views = [ "main" ];
  };
}
