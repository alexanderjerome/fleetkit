{ ... }:

# fleetkit parameter surface — every framework-visible value that is
# specific to YOUR environment, in one place. Keep in sync with
# fleet.toml (the CLI-side twin).

{
  config.fleet.settings = {
    name = "example";

    domain = {
      base = "example.dev";
      internal = "example.lan";
      tailnetSuffix = "hs.example.dev";
    };

    # ACME account registration (internal CA and public Let's Encrypt).
    acmeEmail = "admin@example.dev";

    # SSH public keys for the built-in operator accounts
    # (sysadmin / colmena / dev / root) on every fleet host.
    adminSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample operator@example.dev"
    ];

    # Fleet tailnet (headscale) — uncomment once you run one.
    # tailnet.controlUrl = "https://vpn.example.dev";
    # tailnet.preauthKeyUrl = "https://vpn.example.dev/internal/preauth/fleet-bot";

    network = {
      wanIp = "203.0.113.10";
      lanCidr = "192.0.2.0/24";
      mgmtCidr = "198.51.100.0/24";
      # Where fleet DNS forwards non-fleet queries (gateway or public resolvers).
      upstreamResolvers = [ "192.0.2.1" "1.1.1.1" ];
    };

    # Forward-auth outpost (e.g. Authentik embedded outpost) injected into
    # public vhosts by the caddy module. null = no forward_auth.
    # auth.outpostUrl = "http://192.0.2.13:9000";

    # In-fleet nix binary caches, once you have a builder host.
    cache.substituters = [ ];
    cache.trustedPublicKeys = [ ];

    # OIDC identity provider (Authentik-style) — used by modules that
    # enable OIDC login (e.g. infra.grafana-stack.oidc).
    auth.oidcBaseUrl = "https://auth.example.dev";

    # Observability plumbing — the grafana-stack host every Alloy agent
    # ships telemetry to, plus the Loki chunk store.
    observability = {
      grafanaDomain = "grafana.example.lan";
      prometheusRemoteWriteUrl = "http://192.0.2.4:9090/api/v1/write";
      lokiPushUrl = "http://192.0.2.4:3100/loki/api/v1/push";
      lokiS3Endpoint = "http://s3.example.lan:3900";
      # tempoUrl = "http://192.0.2.9:3200";      # once you run Tempo
      # pveScrapeTargets = { pve1 = "198.51.100.1"; };
      # cpuAlertExcludeRegex = "miner-.*";       # hosts that run hot by design
    };
  };
}
