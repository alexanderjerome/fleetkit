{ config, lib, ... }:

# DNS record derivation from fleet.compute — framework machinery only.
# The DATA (which alias points at which host, static pins, public
# overrides) is supplied by the consumer repo via the options below;
# fleetkit derives the final record sets:
#
#   fleet.dnsRecords       = auto per-host A records (internal_ip)
#                            // resolved service aliases
#                            // fleet.dnsStaticRecords
#   fleet.publicDnsRecords = resolved service aliases
#                            // fleet.dnsPublicOverrides
#
# Consumer paths: an internal DNS server module (e.g. CoreDNS) reads
# `dnsRecords` / `publicDnsRecords`; per-host modules get the same via
# mkHosts helpers (_module.args.helpers).

let
  cfg = config.fleet;

  # eth1 / internal_ip preferred, fall back to eth0.
  _internalIp = h:
    if h ? properties then (h.properties.ipv4 or {}).eth1 or ""
    else h.internal_ip or h.ip or "";

  # Externally-provisioned hosts (provisioning = "external") are
  # excluded: their IPs live outside the fleet network, so a record
  # would resolve but never route for fleet clients.
  fleetHosts = lib.filterAttrs (_: h: (h.provisioning or "managed") == "managed") cfg.hostsJson;

  autoRecords = lib.mapAttrs (_: _internalIp) fleetHosts;

  # service-name → fleet.compute key (resolves to that host's internal IP)
  resolvedAliases =
    lib.mapAttrs (_: hostName: _internalIp (cfg.hostsJson.${hostName} or {}))
      cfg.serviceAliasMap;
in
{
  # ── Consumer-supplied data ──────────────────────────────────────
  options.fleet.serviceAliasMap = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = ''
      subdomain → fleet.compute key. Each alias resolves to that host's
      internal IP in both dnsRecords and publicDnsRecords. Single
      source of truth for "which fleet host hosts which service" —
      also readable by external-DNS zone resources so public and
      internal record sets stay consistent.
    '';
  };

  options.fleet.dnsStaticRecords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = ''
      name → literal IP, merged into dnsRecords last. For service
      aliases pinned to an address rather than a fleet host (edge
      services like ca/ntp/dns on the ingress box).
    '';
  };

  options.fleet.dnsPublicOverrides = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = ''
      name → literal IP, merged into publicDnsRecords last. Split-DNS
      overrides for names whose public zone answer (WAN IP) is not
      reachable from inside the fleet (no NAT hairpin) — point them at
      the internal ingress instead.
    '';
  };

  # ── Derived exports ─────────────────────────────────────────────
  options.fleet.dnsRecords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    internal = true;
    description = "Internal DNS A records (auto + service aliases + static).";
  };

  options.fleet.publicDnsRecords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    internal = true;
    description = "Split-DNS records for the public base domain (aliases + overrides).";
  };

  config.fleet.dnsRecords = autoRecords // resolvedAliases // cfg.dnsStaticRecords;
  config.fleet.publicDnsRecords = resolvedAliases // cfg.dnsPublicOverrides;
}
