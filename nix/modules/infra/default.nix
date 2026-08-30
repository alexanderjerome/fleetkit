# The `infra` module — fleetkit's entire NixOS surface.
#
# base/ is always-on; everything under services/ is gated by
# mkEnableOption and remains inert unless explicitly enabled in a host
# definition. File tree mirrors the option namespace: the module for
# `infra.<name>` lives at ./services/<name>.
{ ... }:
{
  imports = [
    # Always-on foundation: core (slim NixOS base — users, ssh, locale
    # UTC, single-DHCP eth0, nix gc; transitively imports platform) +
    # fleet-member.nix (fleet networking, internal CA, builder cache,
    # alloy, SOPS scaffold).
    ./base

    # Fleet-wide service registry (infra.services).
    ./services.nix

    # ── Gated services (infra.<name>) ──
    ./services/acme-dns # DNS-01 delegation server (de-sprawl the DNS API token)
    ./services/alerts # fleet alert aggregation (rules live beside the modules that own them)
    ./services/alloy
    ./services/apt-cacher-ng
    ./services/argocd.nix
    ./services/builder
    ./services/caddy
    ./services/coredns
    ./services/dhcp
    ./services/docker.nix
    ./services/garage/bootstrap.nix # Garage layout + bucket bootstrap (helper for s3 et al.)
    ./services/grafana-stack
    ./services/host-cert
    ./services/pgbouncer # opt-in co-located connection pooler
    ./services/pgweb # read-only Postgres web UI (fleet-wide bookmarks)
    ./services/postgresql
    ./services/postgresql/stale-lockfile.nix
    ./services/pve-installer-answers # answer-file HTTP server (PVE+PBS unattended install)
    ./services/rabbitmq
    ./services/sssd
    ./services/sssd-probe
    ./services/step-ca
    ./services/tailscale
    ./services/tempo # Tempo trace store
    ./services/valkey
  ];
}
