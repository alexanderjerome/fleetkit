# CLAUDE.md — fleetkit development

Read [AGENTS.md](./AGENTS.md) first — it is the canonical rulebook (iron
rules, API discovery, contribution shape) and applies to every agent.
This file adds the Claude-Code-specific development workflow.

## Project context

Parameterized NixOS fleet framework, extracted from a production
multi-hypervisor deployment and generalized. Primary tech: Nix flakes,
terranix → OpenTofu, colmena, SOPS, click/Python (the `fleet` CLI),
ansible (non-NixOS guests + hypervisor management), mdBook (docs).

Everything in this repo is load-bearing: if a thing can be deleted
without breaking a consumer, it does not belong here. Consumer-specific
content (dashboards, playbooks, endpoints) lives in consumer repos and
comes back through injection options.

## Validation loop

```bash
nix flake check        # THE acceptance gate — all five checks must pass:
                       #   example-fleet     parameter surface complete
                       #   example-tf-render stacks render valid TF JSON
                       #   launcher          CLI builds + runs
                       #   docs              every option documented
                       #   compute-surface-golden  emitters render byte-identically
nix build .#docs       # options site (chapters under fleet/, infra/)
nix build .#options-json
```

Run the check before AND after your change; never commit red.

## Gotchas that have actually bitten

- **Untracked files are invisible to flake eval.** A new file imported
  by Nix code fails `nix flake check` with "path does not exist in Git
  repository" until `git add` (intent-to-add `git add -N` suffices).
- **Option descriptions must be static strings.** Interpolating config
  values into a `description` breaks the standalone docs eval. Refer to
  derived values as literal text (e.g. `<fleet.settings.domain.internal>`).
- **Derived option defaults need `defaultText`** or the docs render an
  unreadable blob (or force an eval).
- **`nix-shell -p` is forbidden in anything the framework executes**
  (tf local-exec hooks, scripts): it needs a channels NIX_PATH that
  flakes-only hosts don't have. Use `nix shell nixpkgs#<pkg> --command …`.
- **XO disk lists are positional** — the provider matches disks by
  index. Never reorder a disks list without checking live VDI order.
- **Terraform disk `size_gb` is ForceNew** — the base size never changes
  after first apply; growth goes through `size_add_gb` / reconcile-disks.
- **New required settings must be feature-gated** (nullOr + assertion in
  the consuming module), never unconditional — the minimum-viable check
  (`example-fleet`) will not catch an option the template happens to set,
  so think, don't rely on CI alone.

## Conventions

- Options: declared in `nix/fleet/settings.nix` (site values) or the
  owning module; every option has a description (CI-enforced), an
  `example` when the shape isn't obvious, RFC5737 / example.com values
  in all examples and templates.
- Ansible variables mirror their `fleet.settings` counterparts by name
  (`fleet_admin_ssh_keys` ↔ `adminSshKeys`) and copy their nullability
  (soft-skip when optional, assert with an actionable message when the
  feature demands it).
- CLI: click groups, one file per group in
  `nix/pkgs/_launcher/fleet_launcher/`, registered in `main.py`. Config
  from `fleet.toml` via `config.py` accessors (eval-free — Nix-side data
  reaches the CLI through built artifacts like `hostsJson` /
  `settings-json`, never `nix eval` at runtime). Runtime env (creds,
  ansible paths, caches) is provisioned by the CLI bootstrap, never by
  the devshell.
- Commits: conventional, present-tense, explain *why*; small verified
  steps; `nix flake check` green before every commit.

## Docs

`docs/generate.py` renders `options.json` into the chapter tree and the
mdBook SUMMARY; hand-written pages live in `docs/src/`. The site deploys
to GitHub Pages on push to main. If you add a top-level option namespace,
extend the generator's grouping (FLEET_ORDER / group_of).
