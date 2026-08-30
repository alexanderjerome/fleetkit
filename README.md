# fleetkit

Reusable fleet provisioning + deployment framework, extracted from a
production Proxmox/XCP-ng estate (ADR-092 / INFRA-218). One toolchain,
any environment:

- **Manifest schema** (`nix/fleet/`): declare compute (LXC/VM), cloud
  resources, providers, network, identities, and DNS as Nix data; get
  validation (unique vm_ids, protect rules, stack grouping) for free.
- **Terranix emitters** (`nix/tf/`): the manifest becomes per-stack
  Terraform JSON for Proxmox VE, Xen Orchestra, Cloudflare — applied
  with OpenTofu, one S3 state key per `env.stack` leaf.
- **NixOS assembly** (`nix/lib/`, `nix/modules/`): the same manifest
  drives Colmena deploys; generic modules (base system, DNS server,
  Caddy, postgres, monitoring shippers, tailnet client, …) read fleet
  data instead of literals.
- **`fleet` CLI** (`nix/pkgs/_launcher/`): deploy (tf + colmena),
  secrets (SOPS), inventory, remote exec, sessions — configured by
  `fleet.toml` at the consumer repo root, extended per-repo via
  `cli-ext/`.
- **Bootstrap images** (`nix/images/`): NixOS LXC template factory,
  XCP-ng installer ISO + disko template, prepared Debian cloud image.

## Consuming

```nix
inputs.fleetkit.url = "...";

fleetkit.lib.mkFleet {
  modules = [ ./fleet ];            # your manifest (data only)
  backend = { bucket = "my-tofu"; };
  globalModules = [ ... ];          # your app modules / sops scaffold
}
```

Start from the template: `nix flake init -t <fleetkit>#minimal`. The
template documents every required parameter (`fleet/settings.nix` +
`fleet.toml` — the Nix-side and CLI-side twins).

Everything environment-specific is a parameter: state bucket, domains,
tailnet suffix, WAN/LAN addressing, CA, binary caches, SOPS layout.
The framework repo evals standalone with zero environment data
(`nix flake check` builds an example fleet end-to-end).

## Status

Actively developed. fleetkit was extracted from (and still drives) a
production estate of 20+ NixOS LXC containers and VMs across Proxmox VE
and XCP-ng, consumed through `mkFleet` as an external flake input — the
framework's API is exercised end-to-end by a real deployment, not just
by the example check.
