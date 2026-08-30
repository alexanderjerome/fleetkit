{ config, lib, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types concatStringsSep mapAttrsToList;
  cfg = config.infra.coredns;

  # Generate zone file content from records attrset (skip empty IPs)
  mkZoneRecords = records: concatStringsSep "\n" (lib.filter (s: s != "") (mapAttrsToList
    (name: ip: if ip != "" then "${name} IN A ${ip}" else "")
    records
  ));

  zoneRecords = mkZoneRecords cfg.records;

  mkZoneFile = zoneDomain: records: ''
    $ORIGIN ${zoneDomain}.
    $TTL 300

    @  IN SOA ns1.${zoneDomain}. admin.${zoneDomain}. (
         2024010101 ; serial
         3600       ; refresh
         900        ; retry
         604800     ; expire
         300        ; minimum
       )

       IN NS ns1.${zoneDomain}.

    ns1 IN A ${cfg.listenAddress}

    ${mkZoneRecords records}
  '';

  hasPublicRecords = cfg.publicRecords != {};

  # Generate a hosts-format file for the public domain overrides
  publicHostsFile = concatStringsSep "\n" (lib.filter (s: s != "") (mapAttrsToList
    (name: ip: if ip != "" then "${ip} ${name}.${cfg.publicDomain}" else "")
    cfg.publicRecords
  ));

  extraZoneBlocks = lib.concatStringsSep "\n" (lib.mapAttrsToList (zone: _: ''
    ${zone} {
      log
      errors
      file /etc/coredns/${zone}.zone ${zone}
    }
  '') cfg.extraZones);

  corefile = ''
    ${cfg.domain} {
      log
      errors
      prometheus :9153

      file /etc/coredns/${cfg.domain}.zone ${cfg.domain}
    }

    ${extraZoneBlocks}

    ${lib.optionalString hasPublicRecords ''
    ${cfg.publicDomain} {
      log
      errors

      hosts /etc/coredns/${cfg.publicDomain}.hosts {
        fallthrough
      }
      forward . ${concatStringsSep " " cfg.forwarders}
    }
    ''}

    . {
      forward . ${concatStringsSep " " cfg.forwarders}
      log
      errors
      cache 30
    }
  '';

  zoneFile = mkZoneFile cfg.domain cfg.records;
  extraZoneFiles = lib.mapAttrs mkZoneFile cfg.extraZones;
in
{
  options.infra.coredns = {
    enable = mkEnableOption "CoreDNS internal DNS server";

    domain = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.settings.domain.internal;
      defaultText = lib.literalExpression "config.fleet.settings.domain.internal";
      description = "DNS zone to serve. Must be non-null when infra.coredns is enabled (asserted).";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address CoreDNS listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 53;
      description = "Port CoreDNS listens on.";
    };

    forwarders = mkOption {
      type = types.listOf types.str;
      default = config.fleet.settings.network.upstreamResolvers;
      defaultText = lib.literalExpression "config.fleet.settings.network.upstreamResolvers";
      description = "Upstream DNS servers for non-local queries.";
    };

    records = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Hostname → IP mapping for A records in the internal zone.";
    };

    publicDomain = mkOption {
      type = types.nullOr types.str;
      default = config.fleet.settings.domain.base;
      defaultText = lib.literalExpression "config.fleet.settings.domain.base";
      description = "Public DNS zone for internal (split-horizon) resolution of public names. Only forced when publicRecords is non-empty (asserted non-null then).";
    };

    publicRecords = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Hostname → IP mapping for the public domain zone (internal resolution only).";
    };

    extraZones = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = {};
      example = lib.literalExpression ''
        { "example.xen" = { pbs = "192.0.2.99"; "platform.pve" = "192.0.2.98"; }; }
      '';
      description = ''
        Additional internal DNS zones beyond `domain`. Outer attrset
        key is the zone name; inner attrset is `record-name → IP`.
        Record names can be multi-label (e.g., "platform.pve",
        "nodes.btc.pve") to express hierarchy within the zone.
        Empty IPs are skipped, same as `records`.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != null;
        message = "infra.coredns.enable is set but infra.coredns.domain is null — set fleet.settings.domain.internal (or infra.coredns.domain explicitly).";
      }
      {
        assertion = !hasPublicRecords || cfg.publicDomain != null;
        message = "infra.coredns.publicRecords is non-empty but infra.coredns.publicDomain is null — set fleet.settings.domain.base (or infra.coredns.publicDomain explicitly).";
      }
    ];

    services.coredns = {
      enable = true;
      config = corefile;
    };

    # INFRA-23: the Corefile references zone files via `file /etc/coredns/*.zone`,
    # so changing a record (zone-file content) leaves the systemd unit unchanged
    # — coredns keeps serving stale data until a manual `systemctl restart
    # coredns`. Key a restart to the zone/hosts content so record changes apply
    # on deploy (e.g. the .nodes chain-gateway zone, fleet A records).
    systemd.services.coredns.restartTriggers =
      [ zoneFile ]
      ++ lib.optional hasPublicRecords publicHostsFile
      ++ lib.attrValues extraZoneFiles;

    # Disable systemd-resolved stub listener — coredns owns port 53.
    services.resolved.settings.Resolve.DNSStubListener = "no";

    # Route internal-domain queries to local CoreDNS so step-ca ACME
    # challenges (and any local service) can resolve internal hostnames.
    networking.nameservers = lib.mkForce [ "127.0.0.1" ];
    networking.search = [ cfg.domain ];

    # Single environment.etc merge so the three sources (primary
    # zone, optional public-hosts file, extraZones zone files) don't
    # collide on the parent attr.
    environment.etc = lib.mkMerge [
      { "coredns/${cfg.domain}.zone".text = zoneFile; }
      (lib.mkIf hasPublicRecords {
        "coredns/${cfg.publicDomain}.hosts".text = publicHostsFile;
      })
      (lib.mapAttrs' (zone: contents: {
        name = "coredns/${zone}.zone";
        value = { text = contents; };
      }) extraZoneFiles)
    ];

    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.firewall.allowedUDPPorts = [ cfg.port ];

    # Ship CoreDNS metrics to Prometheus via Alloy
    infra.alloy.extraConfig = ''

      // ── CoreDNS metrics ─────────────────────────────
      prometheus.scrape "coredns" {
        targets = [
          {"__address__" = "127.0.0.1:9153"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "15s"
        job_name = "coredns"
      }
    '';
  };
}
