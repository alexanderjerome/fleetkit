{ ... }:

# DNS data (schema: fleetkit nix/fleet/dns/default.nix). Per-host A
# records derive automatically from the manifest; declare service
# aliases / static pins as they appear.

{
  # alias → fleet.compute key (resolved to that host's internal IP)
  config.fleet.serviceAliasMap = { };

  # name → literal IP (edge services not tied to one fleet host)
  config.fleet.dnsStaticRecords = { };

  # split-DNS overrides for public names unreachable from inside
  # (no NAT hairpin): point them at the internal ingress IP.
  config.fleet.dnsPublicOverrides = { };
}
