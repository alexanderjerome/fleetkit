{ lib, ... }:

# fleetkit parameter surface (ADR-092 / INFRA-218).
#
# Every environment-specific value the FRAMEWORK itself needs lives
# here, declared front-and-center with no company defaults. The
# consumer repo sets these in one place (conventionally
# `fleet/settings.nix` next to its manifest); framework modules read
# `config.fleet.settings.*` instead of literals.
#
# Requiredness policy: fleetkit users COMPOSE — some run only one
# provider, no tailnet, no observability stack. Therefore no option
# here is unconditionally required unless the always-on base layer
# consumes it (currently only `adminSshKeys`). Everything else is
# `nullOr` with `default = null` (or a generic default) and is
# enforced by an assertion inside the consuming module, so a
# minimum-viable fleet (one host, one provider, no optional services)
# evaluates with only the settings that fleet actually exercises.
#
# Scope note: this is the NIX-side surface (modules, emitters,
# images). The `fleet` CLI reads its operator-side settings from
# `fleet.toml` at the consumer repo root — deliberately a separate,
# eval-free file so the CLI starts fast. Values that both sides need
# (domains, tailnet suffix) are declared in both; keep them in sync.

{
  options.fleet.settings = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "fleet";
      example = "acme";
      description = "Short fleet/org slug. Used for branding and resource-name prefixes (attic cache name, hydra project, step-ca CA name, pgweb bookmarks).";
    };

    domain = {
      base = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "example.dev";
        description = "Public base domain (external DNS zone). null ⇒ no public-name features; required (asserted) by modules that mint public names: caddy devDomain vhosts, coredns split-horizon zone, acme-dns, hydra/grafana mail senders, pve-installer-answers.";
      };
      internal = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "example.pve";
        description = "Internal search/zone domain served by fleet DNS. null ⇒ no internal-FQDN features; required (asserted) by caddy, coredns, host-cert (internal CA), step-ca, hydra, rabbitmq management vhosts.";
      };
      tailnetSuffix = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "hs.example.dev";
        description = "MagicDNS base domain of the fleet tailnet (headscale base_domain). null ⇒ no tailnet serveUI names; required (asserted) when infra.network.tailnet.serveUI entries exist.";
      };
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "admin@example.com";
      description = "Email for ACME account registration (internal CA and public Let's Encrypt). null ⇒ no ACME issuance; required (asserted) by infra.ingress and by host-cert when an internal CA is configured.";
    };

    adminSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEexamplekeyexamplekeyexample operator@example.com" ];
      description = "SSH public keys authorized for the built-in operator accounts (sysadmin / colmena / dev / root) on every fleet host. REQUIRED BY THE BASE LAYER — every NixOS fleet host creates these accounts, so building any host toplevel forces this option.";
    };

    tailnet = {
      controlUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://vpn.example.dev";
        description = "Login/control server URL of the fleet tailnet (headscale). Used as --login-server by infra.network.tailnet.fleetNode. null ⇒ fleetNode emits no --login-server flag.";
      };
      preauthKeyUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://vpn.example.dev/internal/preauth/fleet-bot";
        description = "HTTPS endpoint returning a tailnet preauth key as raw text (e.g. a source-IP-gated headscale vhost). Used by infra.network.tailnet.fleetNode to auto-fetch enrollment keys. null ⇒ hosts fall back to a SOPS-held auth key.";
      };
    };

    auth = {
      outpostUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://192.0.2.13:9000";
        description = "Base URL of the identity provider's forward-auth outpost (e.g. the Authentik embedded outpost). null ⇒ no forward_auth injection by default.";
      };
      oidcBaseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://auth.example.dev";
        description = "Base URL of the fleet's OIDC identity provider (e.g. Authentik). Required by modules that enable OIDC login (e.g. infra.observability.stack.oidc).";
      };
    };

    observability = {
      grafanaDomain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "grafana.example.pve";
        description = "Domain Grafana serves on (server.domain / root_url). null ⇒ no observability stack; required (asserted) when infra.observability.stack is enabled.";
      };
      prometheusRemoteWriteUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://192.0.2.4:9090/api/v1/write";
        description = "Prometheus remote-write endpoint every fleet host's Alloy agent ships metrics to (usually the grafana-stack host). null (together with lokiPushUrl = null) ⇒ Alloy stays disabled by default fleet-wide; required (asserted) when infra.observability.alloy is enabled.";
      };
      lokiPushUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://192.0.2.4:3100/loki/api/v1/push";
        description = "Loki push endpoint every fleet host's Alloy agent ships logs to (usually the grafana-stack host). null (together with prometheusRemoteWriteUrl = null) ⇒ Alloy stays disabled by default fleet-wide; required (asserted) when infra.observability.alloy is enabled.";
      };
      tempoUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://192.0.2.9:3200";
        description = "HTTP URL of the fleet's Tempo trace store. null ⇒ no Tempo datasource is provisioned in Grafana.";
      };
      lokiS3Endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://s3.example.lan:3900";
        description = "S3-compatible endpoint (e.g. in-fleet Garage) Loki writes chunks and index to. null ⇒ no Loki chunk store; required (asserted) when infra.observability.stack is enabled.";
      };
      pveScrapeTargets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { pve1 = "198.51.100.1"; pve2 = "198.51.100.2"; };
        description = "Proxmox VE hypervisors scraped via prometheus-pve-exporter: instance label → node API address. {} ⇒ no PVE targets.";
      };
      cpuAlertExcludeRegex = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "chain-node-.*|miner-.*";
        description = "Prometheus instance-label regex excluded from the fleet-wide high-CPU alert (hosts that legitimately run hot). \"\" ⇒ no exclusions.";
      };
    };

    network = {
      wanIp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "203.0.113.10";
        description = "Public WAN IP of the fleet edge (stable pointer for public DNS pins). null ⇒ no public-edge features; required (asserted) by infra.pki.acmeDns (glue/apex A records).";
      };
      lanCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.0.2.0/24";
        description = "Fleet LAN CIDR (mirrors fleet.network.internal_cidr for module convenience). null ⇒ modules that default network ACLs from it (e.g. infra.data.postgresql.allowedSubnets) default to an empty list instead.";
      };
      mgmtCidr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "198.51.100.0/24";
        description = "Hypervisor/management network CIDR, if separate from the LAN.";
      };
      upstreamResolvers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "1.1.1.1" "9.9.9.9" ];
        example = [ "198.51.100.1" "1.1.1.1" ];
        description = "Upstream DNS servers the fleet DNS forwards non-fleet queries to (e.g. the LAN gateway or public resolvers).";
      };
      staticWanCidrs = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { headscale-router = "198.51.100.7/24"; };
        description = ''
          VM name → WAN-side CIDR for legacy name-dispatch VMs whose
          fleet entry keeps `ip = ""` (so Colmena resolves internal_ip)
          but still needs a pinned WAN address on eth0. Consumed by the
          `headscale-router` branch of nix/lib/tf/proxmox.nix mkVm.
          {} ⇒ no pins; the emitter throws if a VM hits that branch
          without an entry here.
        '';
      };
    };

    providers = {
      proxmox = {
        singleBridgeInstances = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "colo" ];
          description = ''
            Proxmox provider-instance names (the `<inst>` in a fleet
            entry's `provider_instance = "proxmox.<inst>"`) whose PVE
            nodes carry the internal LAN directly on vmbr0 (single-NIC
            nodes, e.g. PVE-on-XCP-ng VMs). Containers on these
            instances default their internal bridge to vmbr0 instead
            of vmbr1; a per-host `internal_bridge` override still wins.
          '';
        };
      };
    };

    githubAccessTokens = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Provision a GitHub machine-user token (SOPS integrations/github/machine_user_token) into nix access-tokens on every host — needed when flake inputs fetch private GitHub repos.";
    };

    internalCa = {
      certFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = lib.literalExpression "./certs/fleet-root-ca.crt";
        description = "Root certificate of the fleet-internal CA (step-ca). Trusted on every host and used as the Caddy ACME root when set.";
      };
      acmeDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://ca.example.lan:9000/acme/acme/directory";
        description = "ACME directory URL of the internal CA. null ⇒ modules default to public Let's Encrypt.";
      };
    };

    cache = {
      substituters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "http://192.0.2.101:5000" ];
        description = "In-fleet nix binary caches trusted by fleet hosts (harmonia/attic/...).";
      };
      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "cache.example.dev:MExampleExampleExampleExampleExampleExampleExa=" ];
        description = "Public keys matching `substituters`.";
      };
    };
  };
}
