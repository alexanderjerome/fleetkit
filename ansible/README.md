# fleetkit `ansible/` — imperative convergence for non-NixOS hosts

Colmena owns every NixOS host declaratively. This tree covers the hosts
Nix can't: **PVE/PBS hypervisors** (Debian under Proxmox) and **Debian
developer guests**, plus a handful of one-shot operational tasks against
NixOS hosts (template/ISO rebuilds on the fleet builder).

## Layout

```
ansible/
├── ansible.cfg              # defaults; inventory comes from the CLI (below)
├── requirements.yml         # collections: community.sops/general, ansible.posix, community.crypto
├── playbooks/
│   ├── site.yml             # pve + pbs + developer, in order
│   ├── pve.yml              # hosts: pve         → base, proxmox/base, proxmox/pve
│   ├── pbs.yml              # hosts: pbs_servers → base, proxmox/base, proxmox/pbs
│   ├── proxmox.yml          # hosts: proxmox     → shared bits only (tag runs)
│   ├── developer.yml        # hosts: developer   → base, developer
│   ├── roles -> ../roles    # symlink so roles resolve from a copied/store tree
│   └── tasks/               # one-shot ops (uncluster-pve-node, refresh-ca-trust,
│                            #   reissue-tailnet-key, rebuild-pve-{template,iso})
└── roles/
    ├── base                 # baseline pkgs, dns-pin, operator SSH, ca-trust, time, tailnet-enroll
    ├── proxmox/base         # repos, nag patch, peer-hosts, grow-storage, ct-watchdog
    ├── proxmox/pve          # bridges, data disks, NFS storage, cluster-join, fstrim, backups, ACME
    ├── proxmox/pbs          # S3-backed datastore config, terraform token issuance
    ├── developer            # dev users/keys, docker, nix, direnv, shell config
    └── nixos/nix-builder    # imperative build byproducts on the NixOS builder host
```

## No static inventory — generate it from the fleet manifest

fleetkit deliberately ships **no `inventory/` directory**. The fleet
manifest (`fleet.compute` → `hosts.json`) is the single source of truth;
a static YAML copy of it would immediately drift. Instead:

```bash
fleet ansible inventory            # writes .cache/fleet/ansible-inventory.yml
fleet ansible run pve --limit pve-1
fleet ansible run tasks/uncluster-pve-node -e pve_node_to_remove=pve-2
```

`fleet ansible inventory` reads the generated `hosts.json` and derives
groups from fleet metadata:

| Group           | Membership rule                                             |
|-----------------|-------------------------------------------------------------|
| `pve`           | tag `pve-host`                                              |
| `pbs_servers`   | tag `pbs`                                                   |
| `proxmox`       | parent of `pve` + `pbs_servers`                             |
| `debian_guests` | `kind = container` with a non-null `image` (non-NixOS LXCs) |
| `developer`     | parent alias of `debian_guests` (what `developer.yml` and the terranix emitter target) |
| `nixos`         | everything else (NixOS LXCs/VMs) — `ansible_python_interpreter` points at the system profile |

Every host gets `ansible_host=<ip or internal_ip>`; hosts with neither
are skipped. `all` vars carry `ansible_user=root` and the operator key
from `fleet.toml [ssh] sysadmin_key_file`.

The `fleet` launcher exports `ANSIBLE_INVENTORY` pointing at the
generated file and `ANSIBLE_ROLES_PATH` covering both this tree and any
consumer-side `ansible/roles`, so plain `ansible-playbook` also works
inside the devshell. Extra inventory vars (group_vars-style tuning such
as `tailnet_accept_routes: false` per host) belong in the consumer repo:
pass them with `-e @vars.yml` or a consumer-side inventory next to the
generated one.

## Variables ↔ `fleet.settings` correspondence

Company/site values are **variables with no company defaults**. Where a
value corresponds to a `fleet.settings` Nix option (see
`nix/fleet/settings.nix`), the ansible variable is named to match and
mirrors its nullability: an *undefined optional* variable soft-skips the
feature; a *required* variable is asserted with an actionable message.

| Ansible variable | fleet.settings option | Required? | Used by |
|---|---|---|---|
| `fleet_admin_ssh_keys` | `adminSshKeys` | **yes** (assert) | base/sysadmin-ssh |
| `fleet_ca_cert_path` | `internalCa.certFile` | no → skip | base/ca-trust, pbs (trusted S3 TLS) |
| `fleet_ca_cert_name` | — (trust-store filename stem) | default `fleet-internal-ca` | base/ca-trust |
| `fleet_dns_servers` | — (fleet DNS resolver IPs; the DNS host serves `domain.base`/`domain.internal`) | no → skip | base/dns-pin |
| `fleet_dns_search` | `domain.base` + `domain.internal` (by convention) | default `[]` | base/dns-pin |
| `fleet_tailnet_control_url` | `tailnet.controlUrl` | no → skip | base/tailnet-enroll |
| `fleet_tailnet_preauth_url` | `tailnet.preauthKeyUrl` | assert iff control URL set | base/tailnet-enroll |
| `fleet_tailnet_key_prefix` | — (headscale key prefix) | default `hskey-auth-` | base/tailnet-enroll |
| `fleet_timezone` | — | default `UTC` | base/time |
| `fleet_domain_internal` | `domain.internal` | no → short names only | proxmox/base peer-hosts |
| `fleet_proxmox_cluster_hosts` | — (cluster member name→IP list) | default `[]` | proxmox/base peer-hosts, pve cluster-join |
| `fleet_acme_email` | `acmeEmail` | assert iff `pve_acme_domains` set | proxmox/pve acme |
| `pve_cluster_creator` | — | assert on joiners | proxmox/pve cluster-join, uncluster task |
| `pve_acme_cf_token_sops_path` / `_keys` | — (SOPS file + key path) | assert iff ACME used | proxmox/pve acme |
| `pbs_s3_endpoint` / `pbs_s3_region` / `pbs_s3_bucket` | — (S3 backend; e.g. in-fleet Garage) | **yes** (assert) | proxmox/pbs |
| `pbs_garage_*_sops_path` | — (SOPS credential files) | **yes** (assert) | proxmox/pbs |
| `nix_builder_repo_path` | — (fleet repo checkout on the builder) | assert in build tasks | nixos/nix-builder |

Everything else in `roles/*/defaults/main.yml` is a generic engineering
default (package lists, timer intervals, LVM growth policy, …) and safe
to ship.

## Module-adjacent playbooks

Operational playbooks that belong to a specific NixOS module live *next
to that module* in `nix/modules/` instead of this tree — e.g.
`nix/modules/infra/build/attic/attic-rebootstrap.yml` sits beside
its module (`default.nix`), whose SOPS credentials it re-mints. They are discovered by
globbing `nix/modules/**/*.yml` in the framework tree (via
`$FLEET_MODULES_DIR`, baked into the Nix-built launcher, with a
repo-relative fallback) and resolve by bare stem at the **lowest**
precedence — a consumer playbook or a `playbooks/` file with the same
name wins:

```bash
fleet ansible playbooks                              # lists them with origin "module"
fleet ansible run attic-rebootstrap -e attic_cache_name=<cache>
```

They follow the same variable conventions as the roles above (required →
assert with an actionable message, optional → soft default). Framework
roles remain available to them: `fleet ansible run` exports
`ANSIBLE_ROLES_PATH` covering both the consumer and framework role
trees. `attic-rebootstrap` variables:

| Ansible variable | Counterpart | Required? |
|---|---|---|
| `attic_cache_name` | `infra.build.attic.cacheName` (Nix default: `fleet.settings.name`) | **yes** (assert) |
| `attic_s3_host` | inventory hostname of the Garage host | default `s3` |
| `attic_builder_host` | inventory hostname of the atticd builder | default `nix-builder` |
| `attic_garage_key_name` | attic module bootstrap key name | default `nix-cache-key` |
| `attic_s3_bucket` | `infra.build.attic.s3Bucket` | default `nix-cache` |
| `attic_garage_env_file` | rendered Garage admin env on the Garage host | default `/run/secrets/rendered/garage-env` |
| `fleet_sops_file` | SOPS secrets file (relative to invocation cwd) | default `nix/secrets/secrets.yaml` |

## Terranix chaining

`nix/tf/compute/ansible.nix` chains these playbooks to provisioned
compute: non-NixOS containers get `playbooks/developer.yml`, VMs tagged
`pve-host` get `playbooks/pve.yml`, both referenced as Nix store paths of
this tree (the `playbooks/roles` symlinks make the copied tree
self-contained). A consumer can substitute its own playbook per compute
entry via `fleet.compute.<name>.ansible_playbook`.
