# Backwards-compatibility shims for the strata restructure.
#
# The flat `infra.<name>` namespace became `infra.<stratum>.<module>`
# (see ./default.nix for the taxonomy). Every old path is aliased onto
# its new home with lib.mkRenamedOptionModule, so existing consumers
# keep evaluating and get a rename warning pointing at the new path.
#
# TWO MECHANISMS, and the choice is not stylistic:
#
#   mkRenamedOptionModule — for LEAF renames (a whole option path down to
#     a scalar). Warns on use, which makes the warning list a migration
#     TODO list. Use wherever the old path is a leaf.
#
#   mkAliasOptionModule — for SUBTREE renames (a whole module's option
#     namespace moving). Does NOT warn, but is the only correct choice,
#     because mkRenamedOptionModule MANGLES PROPERTY WRAPPERS AT NESTED
#     LEAVES. A subtree mkRenamedOptionModule declares the old root as a
#     valueless option and forwards its MERGED definitions; when a consumer
#     writes
#
#         infra.docker.enable = lib.mkDefault true;   # or mkIf / mkForce
#
#     the merge hands the target the raw wrapper attrset
#     `{ _type = "override"; content = true; priority = 1000; }`, which
#     fails the type check with "A definition for option `…enable' is not
#     of type `boolean'". mkAliasOptionModule forwards definitions through
#     mkAliasDefinitions instead, preserving the wrapper semantics.
#
# Found during INFRA-227 consumer parity, where it was NOT a corner case:
# 13 hosts broke on infra.docker, then netcore/nix-builder on infra.sssd,
# then infra.step-ca — one at a time, because each only surfaces on a host
# that actually wraps that option. Every two-element rename below is
# therefore mkAliasOptionModule.
#
# infra.docker and infra.sssd stay as explicit LEAF renames (rather than
# folding into the alias list) so the two most-used moves keep emitting a
# deprecation warning for consumers.
#
# `infra.builder` is the one split move: its scalar root options moved
# to `infra.build.builder.*` (leaf renames) while its sub-features
# became sibling modules of the `build` stratum.
#
# infra.pki.hostCert (./pki/host-cert) declares no options — nothing to
# alias. Delete this file (and these shims) once consumers migrate.
{ lib, ... }:
{
  imports = [
    # network
    (lib.mkAliasOptionModule [ "infra" "coredns" ] [ "infra" "network" "dns" ])
    (lib.mkAliasOptionModule [ "infra" "dhcp" ] [ "infra" "network" "dhcp" ])
    (lib.mkAliasOptionModule [ "infra" "tailscale" ] [ "infra" "network" "tailnet" ])

    # ingress
    (lib.mkAliasOptionModule [ "infra" "caddy" ] [ "infra" "ingress" ])

    # pki
    (lib.mkAliasOptionModule [ "infra" "step-ca" ] [ "infra" "pki" "ca" ])
    (lib.mkAliasOptionModule [ "infra" "acme-dns" ] [ "infra" "pki" "acmeDns" ])

    # observability
    (lib.mkAliasOptionModule [ "infra" "grafana-stack" ] [ "infra" "observability" "stack" ])
    (lib.mkAliasOptionModule [ "infra" "alloy" ] [ "infra" "observability" "alloy" ])
    (lib.mkAliasOptionModule [ "infra" "tempo" ] [ "infra" "observability" "tempo" ])
    (lib.mkAliasOptionModule [ "infra" "alerts" ] [ "infra" "observability" "alerts" ])

    # data
    (lib.mkAliasOptionModule [ "infra" "postgresql" ] [ "infra" "data" "postgresql" ])
    (lib.mkAliasOptionModule [ "infra" "pgbouncer" ] [ "infra" "data" "pgbouncer" ])
    (lib.mkAliasOptionModule [ "infra" "pgweb" ] [ "infra" "data" "pgweb" ])
    (lib.mkAliasOptionModule [ "infra" "valkey" ] [ "infra" "data" "valkey" ])
    (lib.mkAliasOptionModule [ "infra" "rabbitmq" ] [ "infra" "data" "rabbitmq" ])
    (lib.mkAliasOptionModule [ "infra" "garage-bootstrap" ] [ "infra" "data" "s3" ])

    # build — sub-features of the old infra.builder become stratum modules…
    (lib.mkRenamedOptionModule [ "infra" "builder" "attic" ] [ "infra" "build" "attic" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "hydra" ] [ "infra" "build" "hydra" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "lxcTemplateFactory" ] [ "infra" "build" "lxcTemplateFactory" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "wikiPublisher" ] [ "infra" "build" "wikiPublisher" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "registryProxy" ] [ "infra" "build" "registryProxy" ])
    # …while the builder root itself moves to infra.build.builder (leaf renames,
    # because the old root's children fan out to different new homes).
    (lib.mkRenamedOptionModule [ "infra" "builder" "enable" ] [ "infra" "build" "builder" "enable" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "maxJobs" ] [ "infra" "build" "builder" "maxJobs" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "cores" ] [ "infra" "build" "builder" "cores" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "trustedUsers" ] [ "infra" "build" "builder" "trustedUsers" ])
    (lib.mkRenamedOptionModule [ "infra" "builder" "cacheBindAddress" ] [ "infra" "build" "builder" "cacheBindAddress" ])
    (lib.mkAliasOptionModule [ "infra" "apt-cacher-ng" ] [ "infra" "build" "aptCache" ])

    # auth — the probe module folds into sssd as a sub-feature
    # LEAF renames, not a subtree rename — see the mkDefault note at the top.
    (lib.mkRenamedOptionModule [ "infra" "sssd" "enable" ] [ "infra" "auth" "sssd" "enable" ])
    (lib.mkRenamedOptionModule [ "infra" "sssd" "allowedGroups" ] [ "infra" "auth" "sssd" "allowedGroups" ])
    (lib.mkRenamedOptionModule [ "infra" "sssd" "sudoGroups" ] [ "infra" "auth" "sssd" "sudoGroups" ])
    (lib.mkRenamedOptionModule [ "infra" "sssd" "ldapUri" ] [ "infra" "auth" "sssd" "ldapUri" ])
    (lib.mkRenamedOptionModule [ "infra" "sssd" "baseDn" ] [ "infra" "auth" "sssd" "baseDn" ])
    (lib.mkAliasOptionModule [ "infra" "sssdProbe" ] [ "infra" "auth" "sssd" "probe" ])

    # provisioning
    (lib.mkAliasOptionModule [ "infra" "pve-installer-answers" ] [ "infra" "provisioning" "pveInstallerAnswers" ])

    # integrations
    (lib.mkAliasOptionModule [ "infra" "argocd" ] [ "infra" "integrations" "argocd" ])
    # LEAF renames, not a subtree rename — see the mkDefault note at the top.
    (lib.mkRenamedOptionModule [ "infra" "docker" "enable" ] [ "infra" "integrations" "docker" "enable" ])
    (lib.mkRenamedOptionModule [ "infra" "docker" "dataRoot" ] [ "infra" "integrations" "docker" "dataRoot" ])
    (lib.mkRenamedOptionModule [ "infra" "docker" "logDriver" ] [ "infra" "integrations" "docker" "logDriver" ])
    (lib.mkRenamedOptionModule [ "infra" "docker" "registryMirror" ] [ "infra" "integrations" "docker" "registryMirror" ])
  ];
}
