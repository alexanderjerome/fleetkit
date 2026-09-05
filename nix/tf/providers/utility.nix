{ config, lib, stackId ? null, ... }:

# Config-less utility providers (hashicorp/random, /tls, /time,
# /cloudinit). These need ONLY a `required_providers` entry — no
# `provider "<name>" {}` block, no secrets, no state. Their resources
# (random_password, tls_cert_request, time_sleep, cloudinit_config, …)
# work with zero provider configuration.
#
# random/tls/time/cloudinit fire into every stack when declared — tiny
# providers, cheap everywhere. ansible is the exception (ADR-096 A6b): it
# is required ONLY in stacks that actually run playbooks. Before this
# gate, every stack downloaded and locked it at `tofu init` for the
# benefit of exactly one — and unused lock entries are one source of the
# "stale provider lock, needs tf init" failures the drift ledger recorded.

let
  p = config.fleet.providers;
  mkReq = inst: { source = inst.source; version = inst.version; };

  # Mirrors compute/ansible.nix's managed-host convention exactly: a
  # Debian-image container or a pve-host-tagged VM is ansible-managed
  # (ansible_playbook only overrides WHICH playbook, never opts hosts in).
  stackEntries = if stackId == null then [] else (config.fleet.stacks.${stackId} or []);
  ansibleUsed = lib.any (e:
    (e.kind or null) == "container" && (e.image or null) != null
    || (e.kind or null) == "vm" && lib.elem "pve-host" (e.tags or []))
    stackEntries;
in {
  config = lib.mkMerge [
    (lib.mkIf (p.random    != null) { terraform.required_providers.random    = mkReq p.random; })
    (lib.mkIf (p.tls       != null) { terraform.required_providers.tls       = mkReq p.tls; })
    (lib.mkIf (p.time      != null) { terraform.required_providers.time      = mkReq p.time; })
    (lib.mkIf (p.cloudinit != null) { terraform.required_providers.cloudinit = mkReq p.cloudinit; })
    (lib.mkIf (p.ansible   != null && ansibleUsed) { terraform.required_providers.ansible   = mkReq p.ansible; })
  ];
}
