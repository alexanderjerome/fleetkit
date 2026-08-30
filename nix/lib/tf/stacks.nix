{ lib }:

# Helpers for translating the fleet module's per-resource (env, stack)
# classification into terranix stack IDs and filesystem-safe names.

rec {
  # "prod.bitcoin.mainnet" → "prod-bitcoin-mainnet"
  idToSlug = id: lib.replaceStrings [ "." ] [ "-" ] id;

  # "prod-bitcoin-mainnet" → "prod.bitcoin.mainnet"
  slugToId = slug: lib.replaceStrings [ "-" ] [ "." ] slug;

  # Does a leaf ID match a scope (prefix or exact)?
  #   scopeMatches "prod"                "prod.bitcoin.mainnet" → true
  #   scopeMatches "prod.bitcoin"        "prod.bitcoin.mainnet" → true
  #   scopeMatches "prod.bitcoin.mainnet" "prod.bitcoin.mainnet" → true
  #   scopeMatches "dev"                 "prod.bitcoin.mainnet" → false
  scopeMatches = scope: leafId:
    scope == leafId
      || lib.hasPrefix "${scope}." leafId;

  # Enumerate all leaf IDs in a stacks attrset (keys).
  leafIds = stacks: lib.attrNames stacks;

  # Partition leaf IDs matching a scope (returns the matching subset).
  leavesForScope = scope: stacks:
    lib.filter (id: scopeMatches scope id) (leafIds stacks);
}
