"""fleet ansible — inventory generation and playbook execution.

fleetkit ships its Ansible layer (ansible/ at the framework root:
playbooks for PVE/PBS hypervisors and Debian dev guests, plus one-shot
operational task playbooks) but deliberately NO static inventory. The
fleet manifest is the single source of truth for hosts, so the inventory
is *generated* from hosts.json:

    fleet ansible inventory                 # write the generated inventory
    fleet ansible playbooks                 # list resolvable playbooks
    fleet ansible run pve --limit pve-1     # run a framework playbook
    fleet ansible run tasks/uncluster-pve-node -e pve_node_to_remove=x

Group derivation (from fleet metadata):
    tag "pve-host"                → group pve        \\ children of
    tag "pbs"                     → group pbs_servers / group proxmox
    non-NixOS container (image≠∅) → group debian_guests (aliased by
                                    group developer — what developer.yml
                                    and the terranix emitter target)
    everything else               → group nixos (system-profile python)

The framework tree is resolved from $FLEET_ANSIBLE_DIR (baked into the
Nix-built launcher wrapper) with a repo-relative fallback for editable
installs. A consumer repo may keep its own ansible/ tree; its roles are
prepended to ANSIBLE_ROLES_PATH by the env bootstrap in main.py and its
playbooks win name resolution in `fleet ansible run`.

Module-adjacent playbooks: operational playbooks that belong to a
specific NixOS module live next to it in nix/modules/ (e.g.
nix/modules/infra/build/attic/attic-rebootstrap.yml next to
the attic module). They are discovered by globbing nix/modules/**/*.yml in the
framework tree ($FLEET_MODULES_DIR from the Nix wrapper, repo-relative
fallback) and resolve by bare stem, at the lowest precedence.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir

console = Console()

# Cache locations are centralized in _util.fleet_cache_dir() — the
# generated inventory and hosts.json both live under <root>/.cache/fleet/.


def framework_ansible_dir() -> Path | None:
    """Locate fleetkit's ansible/ tree.

    Order: $FLEET_ANSIBLE_DIR (set by the Nix wrapper to the store copy),
    then the tree relative to this module (editable/devshell install:
    nix/pkgs/_launcher/fleet_launcher/ → repo root → ansible/).
    """
    if env := os.environ.get("FLEET_ANSIBLE_DIR"):
        p = Path(env)
        if p.is_dir():
            return p
    candidate = Path(__file__).resolve().parents[4] / "ansible"
    if candidate.is_dir():
        return candidate
    return None


def framework_modules_dir() -> Path | None:
    """Locate fleetkit's nix/modules/ tree (for module-adjacent playbooks).

    Order: $FLEET_MODULES_DIR (set by the Nix wrapper to the store copy),
    then the tree relative to this module (editable/devshell install:
    nix/pkgs/_launcher/fleet_launcher/ → repo root → nix/modules/).
    """
    if env := os.environ.get("FLEET_MODULES_DIR"):
        p = Path(env)
        if p.is_dir():
            return p
    candidate = Path(__file__).resolve().parents[4] / "nix" / "modules"
    if candidate.is_dir():
        return candidate
    return None


def module_playbooks(root: Path | None = None) -> dict[str, Path]:
    """Discover module-adjacent playbooks — consumer AND framework modules.

    Some operational playbooks live next to the NixOS module they service
    (e.g. nix/modules/infra/build/attic/attic-rebootstrap.yml next to
    its module; a consumer's nix/modules/infisical/ansible/*.yml next to
    its infisical module) rather than in ansible/playbooks/. Any ``*.yml``
    under either nix/modules/ tree whose name looks like a playbook slug
    (lowercase, digits, hyphens) is resolvable by its bare stem. Within
    this tier the CONSUMER tree wins a name collision; the whole tier is
    lowest precedence — consumer ansible/playbooks/ and the framework
    ansible/playbooks/ tree both win over it. A playbook-adjacent roles/
    directory resolves naturally (standard Ansible behaviour), so a
    module-adjacent play carries its roles with it.
    """
    import re
    trees: list[Path] = []
    if root is not None and (root / "nix" / "modules").is_dir():
        trees.append(root / "nix" / "modules")
    if (mods := framework_modules_dir()) is not None:
        trees.append(mods)
    out: dict[str, Path] = {}
    # A module-adjacent play's roles/ ride along beside it — their
    # internal task/handler/defaults files are NOT playbooks and must
    # not pollute name resolution.
    skip_parents = {"roles", "tasks", "handlers", "defaults", "vars",
                    "templates", "files", "meta"}
    for tree in trees:
        for p in sorted(tree.rglob("*.yml")):
            if skip_parents & set(p.relative_to(tree).parts[:-1]):
                continue
            if re.fullmatch(r"[a-z][a-z0-9-]*", p.stem):
                out.setdefault(p.stem, p)
    return out


def _hosts_json(root: Path, *, refresh: bool = False) -> dict:
    """Load hosts.json, generating it from the fleet manifest if needed."""
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if refresh or not hosts_file.exists():
        from .inventory import generate_hosts_json
        generate_hosts_json(quiet=True)
    return json.loads(hosts_file.read_text())


def _settings_json(root: Path) -> dict:
    """fleet.settings as built by the consumer flake's settings-json
    package (eval-free: a build artifact, never `nix eval`). Empty when
    the flake does not export it."""
    try:
        out = subprocess.run(
            ["nix", "build", ".#settings-json", "--no-link", "--print-out-paths"],
            cwd=root, check=True, capture_output=True, text=True).stdout.strip()
        return json.loads(Path(out).read_text())
    except (subprocess.CalledProcessError, OSError, ValueError):
        return {}


def build_inventory(hosts: dict, sysadmin_key_file: str, settings: dict | None = None) -> dict:
    """Derive an Ansible inventory dict from hosts.json entries.

    `settings` (fleet.settings) feeds the variables that mirror settings
    by name — today fleet_pve_host_tweaks ↔ providers.proxmox.hostTweaks."""
    pve: dict[str, dict] = {}
    pbs: dict[str, dict] = {}
    debian: dict[str, dict] = {}
    nixos: dict[str, dict] = {}
    skipped: list[str] = []

    for name, meta in sorted(hosts.items()):
        ip = meta.get("ip") or meta.get("internal_ip") or ""
        if not ip:
            skipped.append(name)
            continue
        hostvars: dict = {"ansible_host": ip}
        tags = meta.get("tags", []) or []
        pve_type = str(meta.get("pve_type", ""))
        if "pve-host" in tags:
            pve[name] = hostvars
        elif "pbs" in tags:
            pbs[name] = hostvars
        elif pve_type == "pve.lxc" and meta.get("image"):
            debian[name] = hostvars
        else:
            nixos[name] = hostvars

    if skipped:
        console.print(
            f"[yellow]Skipped {len(skipped)} host(s) without any IP:[/yellow] "
            + ", ".join(skipped))

    all_vars: dict = {
        "ansible_user": "root",
        "ansible_ssh_private_key_file": sysadmin_key_file,
        "ansible_ssh_common_args": "-o StrictHostKeyChecking=accept-new",
    }
    tweaks = (((settings or {}).get("providers") or {}).get("proxmox") or {}).get("hostTweaks") or {}
    if any(v not in (False, None) for v in tweaks.values()):
        all_vars["fleet_pve_host_tweaks"] = tweaks

    return {
        "all": {
            "vars": all_vars,
            "children": {
                "proxmox": {
                    "vars": {"ansible_python_interpreter": "/usr/bin/python3"},
                    "children": {
                        "pve": {"hosts": pve},
                        "pbs_servers": {"hosts": pbs},
                    },
                },
                # `developer` is what the playbooks and the terranix
                # emitter target; `debian_guests` is the fleet-derived
                # membership. Alias via children so both names work.
                "developer": {
                    "vars": {"ansible_python_interpreter": "/usr/bin/python3"},
                    "children": {"debian_guests": {"hosts": debian}},
                },
                "nixos": {
                    "vars": {
                        "ansible_python_interpreter":
                            "/run/current-system/sw/bin/python3",
                    },
                    "hosts": nixos,
                },
            },
        },
    }


def write_inventory(root: Path, *, refresh: bool = False,
                    quiet: bool = False) -> Path:
    """Generate the ansible inventory file from the fleet manifest."""
    import yaml
    from .config import sysadmin_key_file
    hosts = _hosts_json(root, refresh=refresh)
    inv = build_inventory(hosts, sysadmin_key_file(), _settings_json(root))
    out = fleet_cache_dir(root) / "ansible-inventory.yml"
    out.write_text(
        "# Generated by `fleet ansible inventory` from the fleet manifest\n"
        "# (hosts.json). DO NOT EDIT — regenerate instead. Site tuning\n"
        "# belongs in your own vars files (-e @vars.yml) or a consumer\n"
        "# inventory source.\n"
        + yaml.safe_dump(inv, sort_keys=False))
    if not quiet:
        n = sum(len(g) for g in _leaf_groups(inv))
        console.print(f"[green]Wrote[/green] {out} [dim]({n} hosts)[/dim]")
    return out


def _leaf_groups(inv: dict):
    def walk(node: dict):
        if "hosts" in node:
            yield node["hosts"]
        for child in node.get("children", {}).values():
            yield from walk(child)
    yield from walk(inv["all"])


def ensure_inventory(root: Path) -> Path:
    """Return the generated inventory path, regenerating when stale.

    Stale = missing, or older than the current hosts.json.
    """
    inv = fleet_cache_dir(root) / "ansible-inventory.yml"
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if (not inv.exists()
            or not hosts_file.exists()
            or inv.stat().st_mtime < hosts_file.stat().st_mtime):
        return write_inventory(root, quiet=True)
    return inv


def _resolve_playbook(root: Path, name: str) -> Path | None:
    """Resolve a playbook argument to a file.

    Search order: literal path (as given, or repo-relative), consumer
    ansible/playbooks/, framework playbooks/, module-adjacent playbooks
    (nix/modules/**/<name>.yml in the framework tree). `name` may omit
    the .yml suffix and may carry a tasks/ prefix
    (tasks/uncluster-pve-node).
    """
    candidates: list[Path] = []
    literal = Path(name).expanduser()
    candidates += [literal, root / literal]
    for base in (root / "ansible" / "playbooks",):
        candidates += [base / name, base / f"{name}.yml"]
    if fw := framework_ansible_dir():
        base = fw / "playbooks"
        candidates += [base / name, base / f"{name}.yml"]
    for c in candidates:
        if c.is_file():
            return c
    mod = module_playbooks(root).get(name.removesuffix(".yml"))
    if mod is not None and mod.is_file():
        return mod
    return None


@click.group("ansible")
def ansible():
    """Ansible over the fleet — generated inventory + framework playbooks.

    The inventory is derived from the fleet manifest (hosts.json); the
    playbooks ship with fleetkit (PVE/PBS hypervisor convergence, Debian
    dev guests, one-shot ops) or with the consumer repo's own ansible/.
    """


@ansible.command("inventory")
@click.option("--refresh", is_flag=True,
              help="Regenerate hosts.json from the fleet manifest first.")
@click.option("--stdout", "to_stdout", is_flag=True,
              help="Print the inventory YAML instead of writing the file.")
def inventory_cmd(refresh: bool, to_stdout: bool):
    """Generate .cache/fleet/ansible-inventory.yml from the fleet manifest.

    Groups are derived from fleet metadata: tag pve-host → pve, tag pbs →
    pbs_servers (both under proxmox), non-NixOS containers →
    debian_guests (aliased by developer), everything else → nixos.
    """
    root = find_project_root()
    if to_stdout:
        import yaml
        from .config import sysadmin_key_file
        hosts = _hosts_json(root, refresh=refresh)
        click.echo(yaml.safe_dump(
            build_inventory(hosts, sysadmin_key_file()), sort_keys=False))
        return
    write_inventory(root, refresh=refresh)


@ansible.command("playbooks")
def playbooks_cmd():
    """List playbooks resolvable by `fleet ansible run`."""
    root = find_project_root()
    rows: list[tuple[str, Path]] = []
    seen: set[str] = set()
    sources = [(root / "ansible" / "playbooks", "consumer")]
    if fw := framework_ansible_dir():
        sources.append((fw / "playbooks", "fleetkit"))
    for base, origin in sources:
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.yml")):
            rel = str(p.relative_to(base))[: -len(".yml")]
            if rel in seen:
                continue
            seen.add(rel)
            rows.append((rel, origin))
    # Module-adjacent playbooks (lowest precedence on name collision).
    for name in sorted(module_playbooks(root)):
        if name in seen:
            continue
        seen.add(name)
        rows.append((name, "module"))
    for rel, origin in rows:
        console.print(f"  {rel}  [dim]({origin})[/dim]")


@ansible.command("run", context_settings={"ignore_unknown_options": True})
@click.argument("playbook")
@click.option("--limit", default=None,
              help="Ansible --limit host/group pattern.")
@click.option("--tags", default=None, help="Ansible --tags list.")
@click.option("--check", is_flag=True, help="Ansible --check (dry-run).")
@click.option("--refresh", is_flag=True,
              help="Regenerate hosts.json + inventory before running.")
@click.argument("ansible_args", nargs=-1, type=click.UNPROCESSED)
def run_cmd(playbook: str, limit: str | None, tags: str | None, check: bool,
            refresh: bool, ansible_args: tuple[str, ...]):
    """Run a framework (or consumer) playbook against the fleet.

    PLAYBOOK is resolved by name — e.g. `pve`, `pbs`, `site`,
    `tasks/uncluster-pve-node` — from the consumer repo's
    ansible/playbooks/ first, then fleetkit's shipped playbooks
    (`fleet ansible playbooks` lists both). A literal file path also
    works. The generated inventory is refreshed automatically when
    stale. Extra args after the options are passed straight to
    ansible-playbook (e.g. -e pve_node_to_remove=x -vv).
    """
    root = find_project_root()

    resolved = _resolve_playbook(root, playbook)
    if resolved is None:
        console.print(f"[red]ERROR:[/red] no playbook named '{playbook}' — "
                      "try `fleet ansible playbooks`.")
        sys.exit(1)

    if refresh:
        inv = write_inventory(root, refresh=True, quiet=True)
    else:
        inv = ensure_inventory(root)

    fw = framework_ansible_dir()
    env = os.environ.copy()
    # Roles: consumer tree first (override wins), framework tree second.
    roles_paths = [p for p in (
        root / "ansible" / "roles",
        (fw / "roles") if fw else None,
    ) if p and p.is_dir()]
    if roles_paths:
        env["ANSIBLE_ROLES_PATH"] = ":".join(str(p) for p in roles_paths)
    # Config: consumer ansible.cfg wins; else the framework one.
    if not env.get("ANSIBLE_CONFIG"):
        for cfg in (root / "ansible" / "ansible.cfg",
                    (fw / "ansible.cfg") if fw else None):
            if cfg and cfg.is_file():
                env["ANSIBLE_CONFIG"] = str(cfg)
                break
    env.setdefault("ANSIBLE_HOST_KEY_CHECKING", "False")

    cmd = ["ansible-playbook", "-i", str(inv), str(resolved)]
    if limit:
        cmd += ["--limit", limit]
    if tags:
        cmd += ["--tags", tags]
    if check:
        cmd += ["--check"]
    cmd += list(ansible_args)

    console.print(f"[dim]$ {' '.join(cmd)}[/dim]")
    try:
        result = subprocess.run(cmd, cwd=root, env=env)
    except FileNotFoundError:
        console.print("[red]ERROR:[/red] ansible-playbook not found on PATH "
                      "— enter the devshell (nix develop) or install ansible.")
        sys.exit(127)
    sys.exit(result.returncode)
