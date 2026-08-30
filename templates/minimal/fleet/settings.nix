{ ... }:

# fleetkit parameter surface — every framework-visible value that is
# specific to YOUR environment, in one place. Keep in sync with
# fleet.toml (the CLI-side twin).
#
# MINIMUM-VIABLE PRINCIPLE: fleetkit only requires the settings your
# fleet actually exercises. This template enables no optional service,
# so the only required setting here is `adminSshKeys` (consumed by the
# always-on base layer — the operator accounts on every NixOS host).
# Everything else defaults to null/off and is enforced by an assertion
# in the module that needs it, naming the exact setting to add.

{
  config.fleet.settings = {
    # SSH public keys for the built-in operator accounts
    # (sysadmin / colmena / dev) on every fleet host.
    # REQUIRED — the base layer creates these accounts on every host.
    adminSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample operator@example.dev"
    ];

    # ── Full option surface — uncomment as you enable features ────────
    #
    # # Short fleet/org slug (branding + resource-name prefixes:
    # # attic cache, hydra project, step-ca CA name). Default: "fleet".
    # name = "example";

    # # Domains — needed once you serve names:
    # domain = {
    #   base = "example.dev";          # public zone: caddy devDomain vhosts,
    #                                  # coredns split-horizon, acme-dns,
    #                                  # hydra/grafana mail senders
    #   internal = "example.lan";      # internal zone: caddy, coredns,
    #                                  # host-cert, step-ca, hydra, rabbitmq
    #   tailnetSuffix = "hs.example.dev"; # MagicDNS base for tailscale serveUI
    # };

    # # ACME account registration — needed by infra.ingress and by the
    # # host-cert module once internalCa.acmeDirectory is set.
    # acmeEmail = "admin@example.dev";

    # # Fleet tailnet (headscale) — uncomment once you run one.
    # tailnet.controlUrl = "https://vpn.example.dev";
    # tailnet.preauthKeyUrl = "https://vpn.example.dev/internal/preauth/fleet-bot";

    # # Identity provider:
    # auth.outpostUrl = "http://192.0.2.13:9000";  # forward-auth outpost for
    #                                              # public caddy vhosts
    # auth.oidcBaseUrl = "https://auth.example.dev"; # OIDC login (e.g.
    #                                                # infra.observability.stack.oidc)

    # # Edge/network extras:
    # network = {
    #   wanIp = "203.0.113.10";        # public DNS pins (infra.pki.acmeDns)
    #   lanCidr = "192.0.2.0/24";      # default network ACLs (infra.data.postgresql)
    #   mgmtCidr = "198.51.100.0/24";  # hypervisor management net, if separate
    #   upstreamResolvers = [ "192.0.2.1" "1.1.1.1" ]; # coredns forwarders
    # };

    # # In-fleet nix binary caches, once you have a builder host.
    # cache.substituters = [ "http://192.0.2.101:5000" ];
    # cache.trustedPublicKeys = [ "builder:REPLACEME" ];

    # # Internal CA (step-ca) — turns on per-host certs (host-cert module):
    # internalCa.certFile = ./ca-root.crt;
    # internalCa.acmeDirectory = "https://ca.example.lan:9000/acme/acme/directory";

    # # Observability — setting BOTH URLs auto-enables the Alloy agent
    # # fleet-wide; grafanaDomain + lokiS3Endpoint are needed by the
    # # grafana-stack host itself.
    # observability = {
    #   grafanaDomain = "grafana.example.lan";
    #   prometheusRemoteWriteUrl = "http://192.0.2.4:9090/api/v1/write";
    #   lokiPushUrl = "http://192.0.2.4:3100/loki/api/v1/push";
    #   lokiS3Endpoint = "http://s3.example.lan:3900";
    #   tempoUrl = "http://192.0.2.9:3200";      # once you run Tempo
    #   pveScrapeTargets = { pve1 = "198.51.100.1"; };
    #   cpuAlertExcludeRegex = "miner-.*";       # hosts that run hot by design
    # };
  };
}
