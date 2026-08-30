# Backwards-compatibility shims for the strata restructure.
#
# The flat `infra.<name>` namespace became `infra.<stratum>.<module>`
# (see ./default.nix for the taxonomy). Every old path is aliased onto
# its new home with lib.mkRenamedOptionModule, so existing consumers
# keep evaluating and get a rename warning pointing at the new path.
#
# mkRenamedOptionModule works on whole subtrees here: the old root is
# declared as a hidden valueless option and its raw definitions are
# forwarded (with file/priority preserved) into the new tree, while
# reads of the old path return the merged value of the new one. This is
# verified by eval — setting e.g. `infra.caddy.services.foo.port` lands
# on `infra.ingress.services.foo.port` and warns once.
#
# `infra.builder` is the one split move: its scalar root options moved
# to `infra.build.builder.*` (leaf renames) while its sub-features
# became sibling modules of the `build` stratum (subtree renames).
#
# infra.pki.hostCert (./pki/host-cert) declares no options — nothing to
# alias. Delete this file (and these shims) once consumers migrate.
{ lib, ... }:
{
  imports = [
    # network
    (lib.mkRenamedOptionModule [ "infra" "coredns" ] [ "infra" "network" "dns" ])
    (lib.mkRenamedOptionModule [ "infra" "dhcp" ] [ "infra" "network" "dhcp" ])
    (lib.mkRenamedOptionModule [ "infra" "tailscale" ] [ "infra" "network" "tailnet" ])

    # ingress
    (lib.mkRenamedOptionModule [ "infra" "caddy" ] [ "infra" "ingress" ])

    # pki
    (lib.mkRenamedOptionModule [ "infra" "step-ca" ] [ "infra" "pki" "ca" ])
    (lib.mkRenamedOptionModule [ "infra" "acme-dns" ] [ "infra" "pki" "acmeDns" ])

    # observability
    (lib.mkRenamedOptionModule [ "infra" "grafana-stack" ] [ "infra" "observability" "stack" ])
    (lib.mkRenamedOptionModule [ "infra" "alloy" ] [ "infra" "observability" "alloy" ])
    (lib.mkRenamedOptionModule [ "infra" "tempo" ] [ "infra" "observability" "tempo" ])
    (lib.mkRenamedOptionModule [ "infra" "alerts" ] [ "infra" "observability" "alerts" ])

    # data
    (lib.mkRenamedOptionModule [ "infra" "postgresql" ] [ "infra" "data" "postgresql" ])
    (lib.mkRenamedOptionModule [ "infra" "pgbouncer" ] [ "infra" "data" "pgbouncer" ])
    (lib.mkRenamedOptionModule [ "infra" "pgweb" ] [ "infra" "data" "pgweb" ])
    (lib.mkRenamedOptionModule [ "infra" "valkey" ] [ "infra" "data" "valkey" ])
    (lib.mkRenamedOptionModule [ "infra" "rabbitmq" ] [ "infra" "data" "rabbitmq" ])
    (lib.mkRenamedOptionModule [ "infra" "garage-bootstrap" ] [ "infra" "data" "s3" ])

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
    (lib.mkRenamedOptionModule [ "infra" "apt-cacher-ng" ] [ "infra" "build" "aptCache" ])

    # auth — the probe module folds into sssd as a sub-feature
    (lib.mkRenamedOptionModule [ "infra" "sssd" ] [ "infra" "auth" "sssd" ])
    (lib.mkRenamedOptionModule [ "infra" "sssdProbe" ] [ "infra" "auth" "sssd" "probe" ])

    # provisioning
    (lib.mkRenamedOptionModule [ "infra" "pve-installer-answers" ] [ "infra" "provisioning" "pveInstallerAnswers" ])

    # integrations
    (lib.mkRenamedOptionModule [ "infra" "argocd" ] [ "infra" "integrations" "argocd" ])
    (lib.mkRenamedOptionModule [ "infra" "docker" ] [ "infra" "integrations" "docker" ])
  ];
}
