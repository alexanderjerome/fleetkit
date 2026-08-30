{ lib }:

# Derive Headscale ACL bits from the fleet manifest so fleet.nix stays
# the single source of truth. Each compute entry's env/stack/pool/tags
# are projected into Tailscale ACL tag identifiers, and the resulting
# tag set is registered under tagOwners against whichever user holds
# the enrollment preauth key (today: "netgate@").
#
# Tag layout (one host can carry several):
#   tag:env-<env>          - per-environment label (platform, dev, ...)
#   tag:stack-<stack>      - per-stack label (bitcoin-mainnet, data, ...)
#   tag:pool-<pool_id>     - per-pool label (core, services, ...) when pool != null
#   tag:<userTag>          - one for each entry of the host's `tags` list
#
# All identifiers are slugged to [a-z0-9-]+, since Tailscale ACL tags
# disallow dots and other punctuation.

let
  inherit (lib)
    concatMap
    unique
    listToAttrs
    nameValuePair
    optional
    toLower
    ;

  # Slug a string into a tag-safe identifier.
  slug = s:
    let
      lower = toLower s;
      dashed = builtins.replaceStrings [ "." "_" "/" " " ] [ "-" "-" "-" "-" ] lower;
    in dashed;

  mkTag = ns: value: "tag:${ns}-${slug value}";

  # Tags this host should advertise via `tailscale up --advertise-tags=...`.
  tagsFor = entry:
    let
      env = mkTag "env" entry.env;
      stack = mkTag "stack" entry.stack;
      pool = optional (entry.pool != null) (mkTag "pool" entry.pool);
      user = map (t: "tag:${slug t}") (entry.tags or []);
    in unique ([ env stack ] ++ pool ++ user);

  # Union of every tag used across the fleet — needed for tagOwners.
  allTags = fleet:
    unique (concatMap tagsFor (lib.attrValues fleet));

  # tagOwners attrset: every used tag → [ owner ].
  # `owner` is the headscale user identity that holds the preauth key.
  # In headscale v2 the owner spec must contain "@". For a user with no
  # OIDC email, "<username>@" parses but does NOT match at runtime —
  # known v2 quirk. Pass "*" to permit any authenticated user (sufficient
  # while every fleet host enrolls via the same shared preauth key).
  tagOwnersFor = fleet: owner:
    listToAttrs (map (t: nameValuePair t [ owner ]) (allTags fleet));

  # ACL groups for the headscale policy: "group:<name>" → [member refs],
  # derived from fleet.access.users so access.nix stays the single
  # source of truth.
  #
  # Members are the users' EMAIL addresses, not bare usernames: the
  # headscale v2 policy parser requires every user reference to contain
  # "@", and headscale matches an OIDC login to a policy member by
  # email. A bare username makes headscale reject the whole policy and
  # refuse to start (observed 2026-05-21).
  #
  # Only groups with ≥1 member are emitted — headscale also rejects an
  # acls rule whose src references an empty/undefined group — so callers
  # filter their rule list against the keys of this attrset.
  aclGroupsFor = users:
    let
      everyGroup = unique (concatMap (u: u.groups or []) (lib.attrValues users));
      membersOf = g:
        map (u: u.email)
          (lib.attrValues
            (lib.filterAttrs (_: u: lib.elem g (u.groups or [])) users));
      nonEmpty = lib.filter (g: membersOf g != []) everyGroup;
    in
      listToAttrs (map (g: nameValuePair "group:${g}" (membersOf g)) nonEmpty);

in {
  inherit slug mkTag tagsFor allTags tagOwnersFor aclGroupsFor;
}
