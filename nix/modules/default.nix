# Single import point for fleetkit's generic NixOS modules.
#
# Everything lives under the `infra` module — the file tree mirrors the
# option namespace (`infra.*`):
#
#   infra/base/        always-on foundation (core substrate, platform
#                      boot/kernel glue, the fleet-member layer)
#   infra/<stratum>/   gated deployables, grouped into strata — one
#                      module per `infra.<stratum>.<module>` option
#                      (network, ingress, pki, observability, data,
#                      build, auth, provisioning, integrations), inert
#                      unless enabled in a host definition
#
# Consumer repos import their OWN module tree alongside this one (via
# mkFleet's globalModules) for company-specific services; nothing here
# may reference a particular environment — environment values come
# from config.fleet.settings / config.fleet.network.
{ ... }:
{
  imports = [ ./infra ];
}
