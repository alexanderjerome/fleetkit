"""fleet tf — Terranix/OpenTofu stack lifecycle.

Scope is `<env>.<stack>` dot-paths resolved by prefix-match against the
auto-generated leaf stack list. Examples:

    fleet deploy tf list
    fleet deploy tf apply platform.bootstrap
    fleet deploy tf apply platform                    # every platform.* leaf
    fleet deploy tf apply all                         # every leaf
    fleet deploy tf preview platform.core
    fleet deploy tf destroy dev.apps --target api-dev
    fleet deploy tf import platform.bootstrap proxmox_virtual_environment_pool.pool-core core

Every operation flows through `nix build .#tf-<env>-<stack-dashed>` to
regenerate config.tf.json from the unified fleet, then runs
`tofu -chdir=.tf/<env>-<stack-dashed>` in the repo-local workdir.

Destruction safety:
- `destroy` parses config.tf.json and refuses to run if any `--target`
  resolves to a block with `lifecycle.prevent_destroy = true`. The
  unprotect workflow is printed.
- `--target-dependents` doesn't exist in OpenTofu by design (-target is
  upward-only), so a destroy can never cascade downward into dependents.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import click
from rich.console import Console
from rich.table import Table

from ._util import find_project_root, run_shell

console = Console()


# ── On-disk cache (option 1+2: skip Nix when inputs unchanged) ───────
#
# Two layers of caching, both keyed by the same input fingerprint:
#
#   .tf/.cache/stack-ids.json   stack enumeration (replaces a 2-min eval)
#   .tf/<slug>/.cache.json      per-stack config.tf.json freshness marker
#
# Cache key = SHA256 of every file that could materially affect terranix
# output: flake.lock + every .nix under nix/fleet, nix/hosts (per-host
# fleet.compute entries), nix/tf (emitters) and nix/lib (emitter
# helpers). False positives (rebuilding when output would be identical)
# are cheap because Nix dedups in its store; false negatives would be
# incorrect, so the fingerprint stays conservative.

def _input_hash(root: Path) -> str:
    h = hashlib.sha256()
    paths: list[Path] = [root / "flake.lock"]
    paths += sorted((root / "nix" / "fleet").rglob("*.nix"))
    paths += sorted((root / "nix" / "hosts").rglob("*.nix"))
    paths += sorted((root / "nix" / "tf").rglob("*.nix"))
    paths += sorted((root / "nix" / "lib").rglob("*.nix"))
    for p in paths:
        if not p.exists():
            continue
        h.update(str(p.relative_to(root)).encode())
        h.update(b"\0")
        h.update(p.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def _cache_dir(root: Path) -> Path:
    d = root / ".tf" / ".cache"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ── Stack discovery ──────────────────────────────────────────────────

def _leaf_stack_ids(root: Path) -> list[str]:
    """Enumerate every leaf stack — disk-cached.

    On cache hit (input fingerprint matches): returns cached IDs without
    invoking Nix at all.

    On miss: `nix build .#tf-stack-ids` reads the authoritative list from
    a tiny flake-output JSON file (eval-cached, ~ms). The previous code
    did `nix eval --impure --expr 'evalModules ...'` which bypassed the
    eval cache and took 2+ minutes.

    Returns IDs like "platform.bootstrap" (dots, not dashes).
    """
    cache = _cache_dir(root) / "stack-ids.json"
    key = _input_hash(root)
    if cache.exists():
        try:
            blob = json.loads(cache.read_text())
            if blob.get("key") == key and isinstance(blob.get("ids"), list):
                return blob["ids"]
        except (json.JSONDecodeError, OSError):
            pass
    try:
        out = subprocess.check_output(
            ["nix", "build", ".#tf-stack-ids", "--no-link", "--print-out-paths"],
            cwd=root, text=True,
        ).strip()
        ids = sorted(json.loads(Path(out).read_text()))
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        console.print(f"[red]ERROR:[/red] could not enumerate tf stacks: {exc}")
        return []
    try:
        cache.write_text(json.dumps({"key": key, "ids": ids}))
    except OSError:
        pass
    return ids


def _slug(leaf_id: str) -> str:
    """platform.bootstrap → platform-bootstrap"""
    return leaf_id.replace(".", "-")


def _scope_matches(scope: str, leaf_id: str) -> bool:
    """True if `leaf_id` is covered by `scope` (exact or dotted-prefix)."""
    if scope in ("all", "*"):
        return True
    return leaf_id == scope or leaf_id.startswith(scope + ".")


def _resolve_scope(root: Path, scope: str) -> list[str]:
    """Return leaf IDs whose tree path starts with `scope`."""
    all_leaves = _leaf_stack_ids(root)
    hits = [l for l in all_leaves if _scope_matches(scope, l)]
    if not hits:
        console.print(f"[red]ERROR:[/red] No leaf stacks match scope '{scope}'.")
        console.print("Available leaves:")
        for l in all_leaves:
            console.print(f"  {l}")
        sys.exit(1)
    return hits


# ── Workdir management ───────────────────────────────────────────────

def _workdir(root: Path, leaf_id: str) -> Path:
    """.tf/<slug>/ — where tofu init + apply run."""
    return root / ".tf" / _slug(leaf_id)


def _stage_json(root: Path, leaf_id: str) -> Path:
    """Materialise .tf/<slug>/config.tf.json — skipping `nix build` when fresh.

    A sidecar `.cache.json` records the input fingerprint that produced
    the current `config.tf.json`. If the fingerprint still matches, we
    skip the Nix invocation entirely (a few seconds per call). Forcing a
    rebuild is `rm -rf .tf/<slug>` (or `rm .tf/<slug>/.cache.json`).
    """
    slug = _slug(leaf_id)
    workdir = _workdir(root, leaf_id)
    workdir.mkdir(parents=True, exist_ok=True)
    dest = workdir / "config.tf.json"
    sidecar = workdir / ".cache.json"
    key = _input_hash(root)

    if dest.exists() and sidecar.exists():
        try:
            if json.loads(sidecar.read_text()).get("key") == key:
                return workdir
        except (json.JSONDecodeError, OSError):
            pass

    out = subprocess.check_output(
        ["nix", "build", f".#tf-{slug}", "--no-link", "--print-out-paths"],
        cwd=root, text=True,
    ).strip()
    if not out:
        console.print(f"[red]ERROR:[/red] nix build .#tf-{slug} produced no output")
        sys.exit(1)
    shutil.copy(out, dest)
    dest.chmod(0o644)
    try:
        sidecar.write_text(json.dumps({"key": key}))
    except OSError:
        pass
    return workdir


def _ensure_init(workdir: Path) -> None:
    """Run `tofu init` if `.terraform/` is absent."""
    if not (workdir / ".terraform").exists():
        subprocess.run(["tofu", "init"], cwd=workdir, check=True)


# ── State-address helpers (rekey) ────────────────────────────────────

def _state_addresses(workdir: Path) -> list[str]:
    """Every resource address in the leaf's tofu state (`tofu state list`)."""
    try:
        out = subprocess.check_output(["tofu", "state", "list"], cwd=workdir, text=True)
    except subprocess.CalledProcessError as exc:
        console.print(f"[red]ERROR:[/red] `tofu state list` failed: {exc}")
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def _name_segment(addr: str) -> str:
    """Resource-name component of a state address (the fleet key).

    `proxmox_virtual_environment_container.observe`       → `observe`
    `module.net.proxmox_x.observe["eth0"]`                → `observe`

    The emitter names resources after the fleet entry's attr key, so this
    segment is exactly what a host rename changes.
    """
    base = addr.split("[", 1)[0]
    return base.rsplit(".", 1)[-1]


def _rekey_address(addr: str, new_name: str) -> str:
    """Swap the resource-name segment of `addr` for `new_name`, keeping any
    `[index]` / `["key"]` suffix and any `module.` prefix intact."""
    base, sep, idx = addr.partition("[")
    prefix, dot, _name = base.rpartition(".")
    new_base = f"{prefix}{dot}{new_name}" if dot else new_name
    return new_base + (sep + idx if sep else "")


# ── Destruction safety preflight ─────────────────────────────────────

def _protected_targets(workdir: Path) -> set[str]:
    """Parse config.tf.json; return `{<type>.<name>}` addresses whose
    resource block carries `lifecycle.prevent_destroy = true`."""
    cfg_path = workdir / "config.tf.json"
    if not cfg_path.exists():
        return set()
    with open(cfg_path) as f:
        cfg = json.load(f)
    protected: set[str] = set()
    for typ, entries in (cfg.get("resource") or {}).items():
        for name, body in entries.items():
            lifecycle = body.get("lifecycle", [])
            if isinstance(lifecycle, list) and lifecycle and lifecycle[0].get("prevent_destroy"):
                protected.add(f"{typ}.{name}")
    return protected


def _raise_if_target_protected(workdir: Path, targets: list[str]) -> None:
    """Abort destroy if any target is protected."""
    if not targets:
        return
    protected = _protected_targets(workdir)
    hits = [t for t in targets if t in protected]
    if hits:
        console.print(f"[red]ERROR:[/red] Refusing to destroy protected resource(s): {hits}")
        console.print("")
        console.print("Unprotect workflow:")
        console.print("  1. Edit the fleet entry in nix/fleet/{fleet,resources}.nix: set protect = false")
        console.print("     (OR remove the stateful tag that forced it via destruction_policy)")
        console.print("  2. `fleet deploy tf apply <scope>` — lifecycle.prevent_destroy is removed")
        console.print("  3. `fleet deploy tf destroy <scope> --target <name>`")
        console.print("  4. Re-enable protect=true before the next apply")
        sys.exit(1)


# ── CLI ──────────────────────────────────────────────────────────────

@click.group("tf")
def tf_stacks() -> None:
    """Terranix/OpenTofu stack lifecycle.

    Scope is `<env>.<stack>` dot-paths. Prefix-match selects leaves.
    """
    pass


@tf_stacks.command("list")
def tf_list() -> None:
    """Enumerate leaf stacks."""
    root = find_project_root()
    leaves = _leaf_stack_ids(root)
    t = Table(title="Terranix leaf stacks")
    t.add_column("Stack ID", style="cyan")
    t.add_column("State prefix", style="dim")
    for l in leaves:
        t.add_row(l, f"tf/{_slug(l)}/")
    console.print(t)


@tf_stacks.command("preview")
@click.argument("scope")
@click.option("--target", multiple=True,
              help="Pass through to tofu -target. Can repeat. Limited to a single leaf.")
def tf_preview(scope: str, target: tuple[str, ...]) -> None:
    """tofu plan for leaves matching SCOPE."""
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if target and len(leaves) > 1:
        console.print(f"[red]ERROR:[/red] --target requires a single leaf (got {len(leaves)}).")
        sys.exit(1)
    for leaf in leaves:
        console.print(f"── preview {leaf} ──", style="bold cyan")
        wd = _stage_json(root, leaf)
        _ensure_init(wd)
        cmd = ["tofu", "plan"]
        for t in target:
            cmd += [f"-target={t}"]
        subprocess.run(cmd, cwd=wd, check=False)


@tf_stacks.command("apply")
@click.argument("scope")
@click.option("--target", multiple=True,
              help="Pass through to tofu -target. Can repeat. Limited to a single leaf.")
@click.option("--yes/--interactive", default=False,
              help="Pass -auto-approve to tofu.")
@click.option("--parallelism", default=3, type=int)
@click.option("--inventory/--no-inventory", default=True, show_default=True,
              help="After apply, refresh .cache/fleet/hosts.json from XOA (qemu-guest-agent "
                   "IP discovery for XCP-ng VMs). Only triggers on env=infra leaves; "
                   "proxmox applies skip the refresh regardless.")
def tf_apply(scope: str, target: tuple[str, ...], yes: bool, parallelism: int, inventory: bool) -> None:
    """tofu apply for leaves matching SCOPE.

    Post-apply inventory refresh policy:

      - env=infra (XCP-ng/XOA) leaves: refresh .cache/fleet/hosts.json so
        tier-0 VMs' DHCP-assigned IPs land in the inventory.
      - env=platform / env=dev (Proxmox) leaves: skipped. Proxmox CT
        IPs are declared statically in fleet; no discovery needed and
        the nix build cost isn't worth paying on every PVE apply.

    Pass --no-inventory to suppress even for XOA applies.
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if target and len(leaves) > 1:
        console.print(f"[red]ERROR:[/red] --target requires a single leaf (got {len(leaves)}).")
        sys.exit(1)

    # Track which applied leaves are XOA-affecting (env=infra).
    # Proxmox leaves don't trigger inventory refresh — Proxmox CT
    # IPs are static-declared, not DHCP-discovered.
    xoa_applied = False
    for leaf in leaves:
        console.print(f"── apply {leaf} ──", style="bold cyan")
        wd = _stage_json(root, leaf)
        _ensure_init(wd)
        cmd = ["tofu", "apply", f"-parallelism={parallelism}"]
        if yes:
            cmd.append("-auto-approve")
        for t in target:
            cmd += [f"-target={t}"]
        result = subprocess.run(cmd, cwd=wd, check=False)
        if result.returncode == 0 and leaf.startswith("infra."):
            xoa_applied = True

    if inventory and xoa_applied:
        console.print("[dim]── refreshing .cache/fleet/hosts.json from XOA ──[/dim]")
        try:
            from .inventory import generate_hosts_json
            generate_hosts_json(quiet=True)
            console.print("[green]✓[/green] inventory refreshed")
            console.print(
                "[dim]Tip: if a tier-0 VM's IP shows as empty, the guest agent "
                "may not have reported yet — re-run [bold]fleet inventory generate[/bold] "
                "in 30s.[/dim]"
            )
        except Exception as exc:
            console.print(f"[yellow]Warning:[/yellow] inventory refresh skipped: {exc}")


@tf_stacks.command("destroy")
@click.argument("scope")
@click.option("--target", multiple=True,
              help="Specific resource address to destroy. Preflight refuses if protected.")
@click.option("--yes/--interactive", default=False)
def tf_destroy(scope: str, target: tuple[str, ...], yes: bool) -> None:
    """tofu destroy for leaves matching SCOPE (preflight-protected)."""
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if target and len(leaves) > 1:
        console.print(f"[red]ERROR:[/red] --target requires a single leaf.")
        sys.exit(1)
    for leaf in leaves:
        wd = _stage_json(root, leaf)
        _raise_if_target_protected(wd, list(target))
        console.print(f"── destroy {leaf} ──", style="bold red")
        _ensure_init(wd)
        cmd = ["tofu", "destroy"]
        if yes:
            cmd.append("-auto-approve")
        for t in target:
            cmd += [f"-target={t}"]
        subprocess.run(cmd, cwd=wd, check=False)


@tf_stacks.command("import")
@click.argument("leaf")
@click.argument("address")
@click.argument("id_")
def tf_import(leaf: str, address: str, id_: str) -> None:
    """tofu import ADDRESS ID_ into the state for LEAF.

    Example:
      fleet deploy tf import platform.bootstrap \\
          proxmox_virtual_environment_pool.pool-core core
    """
    root = find_project_root()
    leaves = _resolve_scope(root, leaf)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] import needs exactly one leaf, got: {leaves}")
        sys.exit(1)
    wd = _stage_json(root, leaves[0])
    _ensure_init(wd)
    subprocess.run(["tofu", "import", address, id_], cwd=wd, check=False)


@tf_stacks.command("refresh")
@click.argument("scope")
def tf_refresh(scope: str) -> None:
    """tofu refresh for matched leaves."""
    root = find_project_root()
    for leaf in _resolve_scope(root, scope):
        console.print(f"── refresh {leaf} ──", style="bold cyan")
        wd = _stage_json(root, leaf)
        _ensure_init(wd)
        subprocess.run(["tofu", "refresh"], cwd=wd, check=False)


@tf_stacks.command("init")
@click.argument("scope")
@click.option("--upgrade/--no-upgrade", default=False,
              help="Pass -upgrade to tofu init (refreshes provider lock).")
def tf_init(scope: str, upgrade: bool) -> None:
    """tofu init for matched leaves.

    Use --upgrade to refresh .terraform.lock.hcl after the provider set
    in nix/terranix/providers/ changes (e.g. when a new provider is
    added to the shared providers/default.nix). Plain `init` is normally
    handled implicitly by preview/apply/destroy/refresh/import — only
    invoke this directly when you need lock-file maintenance.
    """
    root = find_project_root()
    for leaf in _resolve_scope(root, scope):
        console.print(f"── init {leaf}{' (upgrade)' if upgrade else ''} ──", style="bold cyan")
        wd = _stage_json(root, leaf)
        cmd = ["tofu", "init"]
        if upgrade:
            cmd.append("-upgrade")
        subprocess.run(cmd, cwd=wd, check=False)


@tf_stacks.command("state-untaint")
@click.argument("scope")
@click.argument("addr")
def tf_state_untaint(scope: str, addr: str) -> None:
    """tofu untaint ADDR for the single leaf SCOPE.

    Clears the tainted flag on a resource so the next plan doesn't
    force replacement. Useful after a provider-side hiccup left a
    resource in a half-applied state (e.g. provider returned
    unexpected attribute on create).
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] state-untaint requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    console.print(f"── state-untaint {leaf}: {addr} ──", style="bold cyan")
    wd = _stage_json(root, leaf)
    _ensure_init(wd)
    subprocess.run(["tofu", "untaint", addr], cwd=wd, check=False)


@tf_stacks.command("state-rm")
@click.argument("scope")
@click.argument("addr")
def tf_state_rm(scope: str, addr: str) -> None:
    """tofu state rm ADDR for the single leaf SCOPE.

    Removes a resource from tofu state without touching the real
    infrastructure. Useful when a provider renames a resource type and
    `state mv` refuses (it requires same type both sides); pair this
    with `tf apply` to have the new resource type take ownership of
    the existing infra.
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] state-rm requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    console.print(f"── state-rm {leaf}: {addr} ──", style="bold cyan")
    wd = _stage_json(root, leaf)
    _ensure_init(wd)
    subprocess.run(["tofu", "state", "rm", addr], cwd=wd, check=False)


@tf_stacks.command("state-mv")
@click.argument("scope")
@click.argument("from_addr")
@click.argument("to_addr")
def tf_state_mv(scope: str, from_addr: str, to_addr: str) -> None:
    """tofu state mv FROM_ADDR TO_ADDR for the single leaf SCOPE.

    Migrates an existing resource to a new address without destroy +
    recreate. Useful when a provider renames a resource type (e.g.
    proxmox_virtual_environment_cluster_options →
    proxmox_cluster_options in bpg/proxmox).

    Example:
      fleet deploy tf state-mv platform.bootstrap \\
        proxmox_virtual_environment_cluster_options.foo \\
        proxmox_cluster_options.foo
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] state-mv requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    console.print(f"── state-mv {leaf}: {from_addr} → {to_addr} ──", style="bold cyan")
    wd = _stage_json(root, leaf)
    _ensure_init(wd)
    subprocess.run(["tofu", "state", "mv", from_addr, to_addr], cwd=wd, check=False)


@tf_stacks.command("rekey")
@click.argument("scope")
@click.argument("old_name")
@click.argument("new_name")
@click.option("--dry-run", is_flag=True,
              help="Print the `state mv` commands without running them.")
@click.option("--yes", is_flag=True, help="Skip the confirmation prompt.")
def tf_rekey(scope: str, old_name: str, new_name: str, dry_run: bool, yes: bool) -> None:
    """Rename an instantiated resource's STATE key: OLD_NAME → NEW_NAME.

    Renaming a host in the fleet makes OpenTofu see the renamed entry as
    "destroy old + create new" — catastrophic for a stateful container.
    This moves every state address whose resource-name segment is exactly
    OLD_NAME (the container plus any sibling resources the emitter keys
    off the same fleet name) to NEW_NAME, so the next `apply` is an
    in-place update instead of a replace. It codifies the manual
    `tofu state mv`-before-apply dance a host rename otherwise requires.

    This is only the STATE half of a rename. Full workflow:

      1. Rename the fleet entry yourself: the attr key in
         nix/hosts/<provider>/<old>.nix, the hostsRegistry key, and the
         file → <new>.nix.
      2. fleet deploy tf rekey <stack> <old> <new>     ← you are here
      3. fleet deploy tf apply <stack> --target <type>.<new>
         (the PVE guest name/hostname updates in place)

    Touches tofu state only — never running infra, and never the Nix
    files (do step 1 first). The trailing plan flags a destroy/replace if
    the rename was incomplete (a sibling wasn't moved) or an attr drifted.

    Example:
      fleet deploy tf rekey platform.core oldname newname
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] rekey requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    if old_name == new_name:
        console.print("[red]ERROR:[/red] OLD_NAME and NEW_NAME are identical — nothing to do.")
        sys.exit(1)

    wd = _stage_json(root, leaf)
    _ensure_init(wd)

    addresses = _state_addresses(wd)
    matches = [a for a in addresses if _name_segment(a) == old_name]
    if not matches:
        console.print(f"[red]ERROR:[/red] No state addresses with resource name "
                      f"'{old_name}' in {leaf}.")
        near = [a for a in addresses if old_name in a]
        if near:
            console.print("[yellow]Near matches[/yellow] (name segment must match exactly):")
            for a in near:
                console.print(f"  {a}")
        sys.exit(1)

    # Collision guard: refuse if NEW_NAME already owns state here — the
    # apply would have conflicted too.
    collisions = [a for a in addresses if _name_segment(a) == new_name]
    if collisions:
        console.print(f"[red]ERROR:[/red] '{new_name}' already exists in {leaf} state: "
                      f"{collisions}")
        console.print("Resolve the collision before rekeying.")
        sys.exit(1)

    moves = [(a, _rekey_address(a, new_name)) for a in matches]

    console.print(f"── rekey {leaf}: {old_name} → {new_name} ──", style="bold cyan")
    console.print(f"[dim]{len(moves)} state address(es) to move:[/dim]")
    for src, dst in moves:
        console.print(f"  {src}  →  {dst}")

    # Report-only heads-up: addresses that merely contain the old name but
    # whose name segment differs (e.g. a DNS record `dns-observe`). We do
    # NOT auto-move these — that would risk false matches — but flag them
    # so the operator can `state-mv` them by hand if they belong here.
    untouched = [a for a in addresses
                 if old_name in a and _name_segment(a) != old_name]
    if untouched:
        console.print("")
        console.print("[yellow]Note:[/yellow] contain the old name but the name segment "
                      "doesn't match exactly — NOT moved:")
        for a in untouched:
            console.print(f"  {a}")
        console.print("[dim]If they belong to this host, move them with "
                      "`fleet deploy tf state-mv` manually.[/dim]")

    if dry_run:
        console.print("")
        console.print("[dim]--dry-run: equivalent commands ──[/dim]")
        for src, dst in moves:
            console.print(f"  tofu -chdir=.tf/{_slug(leaf)} state mv '{src}' '{dst}'")
        return

    if not yes and not click.confirm(f"Move {len(moves)} state address(es)?", default=False):
        console.print("Aborted.")
        return

    for src, dst in moves:
        console.print(f"  mv {src} → {dst}", style="dim")
        res = subprocess.run(["tofu", "state", "mv", src, dst], cwd=wd, check=False)
        if res.returncode != 0:
            console.print(f"[red]ERROR:[/red] state mv failed for {src}; stopping. State is "
                          "partially migrated — finish the remaining moves manually.")
            sys.exit(1)

    console.print("[green]✓[/green] state rekeyed. Verifying with a targeted plan…")
    new_addr_types = sorted({dst.split("[", 1)[0] for _, dst in moves})
    cmd = ["tofu", "plan"]
    for a in new_addr_types:
        cmd += [f"-target={a}"]
    subprocess.run(cmd, cwd=wd, check=False)
    console.print("")
    console.print("[dim]If the plan above shows a destroy/replace, the rename was incomplete "
                  "(a sibling wasn't moved) or an attribute drifted. Otherwise finish with "
                  f"[bold]fleet deploy tf apply {leaf} --target {new_addr_types[0]}[/bold] to land "
                  "the in-place hostname update.[/dim]")

@tf_stacks.command("state-pull")
@click.argument("scope")
@click.argument("out", type=click.Path(dir_okay=False))
def tf_state_pull(scope: str, out: str) -> None:
    """tofu state pull for the single leaf SCOPE, written to OUT.

    Dumps the remote state as JSON for offline inspection or surgical
    edits (e.g. rewriting a stale node_name that blocks refresh). Pair
    with `state-push` after editing; remember to increment the
    top-level `serial` field or the push is rejected.
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] state-pull requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    console.print(f"── state-pull {leaf} → {out} ──", style="bold cyan")
    wd = _stage_json(root, leaf)
    _ensure_init(wd)
    with open(out, "w") as f:
        subprocess.run(["tofu", "state", "pull"], cwd=wd, check=True, stdout=f)


@tf_stacks.command("state-push")
@click.argument("scope")
@click.argument("statefile", type=click.Path(exists=True, dir_okay=False))
def tf_state_push(scope: str, statefile: str) -> None:
    """tofu state push STATEFILE for the single leaf SCOPE.

    Uploads a locally edited state. tofu refuses lineage mismatches and
    stale serials by default (no -force here on purpose) — pull with
    `state-pull`, edit, bump `serial`, then push. Back the original up
    first; state surgery has no undo beyond your copy.
    """
    root = find_project_root()
    leaves = _resolve_scope(root, scope)
    if len(leaves) != 1:
        console.print(f"[red]ERROR:[/red] state-push requires exactly one leaf (got {len(leaves)}).")
        sys.exit(1)
    leaf = leaves[0]
    console.print(f"── state-push {leaf} ← {statefile} ──", style="bold cyan")
    wd = _stage_json(root, leaf)
    _ensure_init(wd)
    subprocess.run(["tofu", "state", "push", statefile], cwd=wd, check=True)


@tf_stacks.command("state-export")
@click.argument("scope", default="all")
@click.option("--out-dir", default="state-export", show_default=True,
              type=click.Path(file_okay=False),
              help="Directory to write <leaf>.tfstate.json files into.")
def tf_state_export(scope: str, out_dir: str) -> None:
    """Export live tfstate JSON for SCOPE (or the whole fleet) to files.

    SCOPE is a leaf id or prefix (default "all" = every leaf stack). One
    <env>-<stack>.tfstate.json per leaf lands in --out-dir, plus a
    manifest.json listing what was exported. Read-only: this is
    `tofu state pull` per stack, nothing is modified.
    """
    import json as _json

    root = find_project_root()
    leaves = _resolve_scope(root, scope or "all")
    if not leaves:
        console.print("[red]ERROR:[/red] no leaf stacks matched.")
        sys.exit(1)
    outp = Path(out_dir)
    outp.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for leaf in leaves:
        slug = leaf.replace(".", "-")
        dest = outp / f"{slug}.tfstate.json"
        console.print(f"── state-export {leaf} → {dest} ──", style="bold cyan")
        wd = _stage_json(root, leaf)
        _ensure_init(wd)
        with open(dest, "w") as f:
            rc = subprocess.run(["tofu", "state", "pull"], cwd=wd, check=False, stdout=f)
        ok = rc.returncode == 0 and dest.stat().st_size > 0
        manifest[leaf] = {"file": dest.name, "ok": ok}
        if not ok:
            console.print(f"[yellow]WARN:[/yellow] export failed for {leaf}")
    (outp / "manifest.json").write_text(_json.dumps(manifest, indent=2))
    good = sum(1 for m in manifest.values() if m["ok"])
    console.print(f"exported {good}/{len(manifest)} stacks → {outp}/", style="bold green")


__all__ = ["tf_stacks"]


@tf_stacks.command("backend-check")
@click.option("--stack", default=None,
              help="Check the backend this stack resolves to (honours perStack overrides).")
def tf_backend_check(stack: str | None) -> None:
    """Diagnose the tofu state backend: creds, reachability, bucket access.

    Answers the question `tofu init` refuses to: WHY did the backend fail.
    tofu reports "No valid credential sources found" both when the secret was
    never found and when it was found and rejected — two completely different
    problems with the same message, and one of them is a one-line config fix.

    Stages, each reported separately:
      1. what backend this fleet (or one stack) resolves to
      2. where credentials came from — which SOPS file, whether the key
         existed there, and whether the environment already overrode it
      3. whether AWS accepts them (STS)
      4. whether the bucket exists and is readable
    """
    from . import config as _config
    root = find_project_root()
    backend = _config.get("backend", {}) or {}
    ok = True

    # ── 1. resolved backend ────────────────────────────────────────
    btype = backend.get("type") or "s3"
    per = backend.get("per_stack") or backend.get("perStack") or {}
    if stack:
        slug = stack.replace(".", "-")
        override = per.get(slug) or {}
        if override:
            btype = override.get("type", btype)
            console.print(f"[cyan]backend[/cyan]  {stack} overrides the fleet backend → {override}")
    console.print(f"[cyan]backend[/cyan]  type={btype}"
                  + (f" bucket={backend.get('bucket')} region={backend.get('region')}"
                     if btype == "s3" else ""))
    if btype == "local":
        console.print("[green]OK[/green]       local state — no credentials, no bucket, "
                      "nothing to check. State lives in .tf/<slug>/terraform.tfstate.")
        return
    if per:
        console.print(f"[dim]         per-stack overrides declared for: "
                      f"{', '.join(sorted(per))}[/dim]")

    # ── 2. credential provenance ───────────────────────────────────
    # Mirrors main.py's resolution exactly, including its precedence, so this
    # reports what the launcher actually sees rather than an idealised view.
    env_id = os.environ.get("AWS_ACCESS_KEY_ID")
    if env_id:
        console.print(f"[yellow]creds[/yellow]    AWS_ACCESS_KEY_ID already in the environment "
                      f"({env_id[:4]}…{env_id[-3:]}) — the environment WINS over SOPS "
                      f"(the launcher uses setdefault).")
    # Ask for the TREE, not a file: once fleet.settings.sopsFiles routes
    # `integrations`, reporting a FAIL because the *default* file lacks it is
    # a false positive — and a diagnostic that cries wolf stops being read.
    from .config import integrations_file as _cfg_secrets
    cfg_file = Path(str(_cfg_secrets()))
    sops = shutil.which("sops")
    if not sops:
        console.print("[red]FAIL[/red]     `sops` not on PATH — run inside `nix develop`.")
        sys.exit(1)

    def _extract(path: Path):
        r = subprocess.run([sops, "-d", "--extract", '["integrations"]["aws"]', str(path)],
                           capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            return None, (r.stderr or "").strip().splitlines()[-1:] or [""]
        import yaml
        return yaml.safe_load(r.stdout), None

    creds, err = (None, None)
    if cfg_file.is_file():
        creds, err = _extract(cfg_file)
    if creds:
        console.print(f"[green]creds[/green]    integrations.aws found in {cfg_file}")
    else:
        console.print(f"[red]FAIL[/red]     integrations.aws NOT in {cfg_file} "
                      f"— the file this fleet routes the integrations tree to")
        ok = False
        # A split SOPS store is the usual cause; say where it actually lives.
        for sibling in sorted(cfg_file.parent.glob("*.yaml")):
            if sibling == cfg_file:
                continue
            found, _ = _extract(sibling)
            if found:
                console.print(f"[yellow]  →[/yellow]      it IS in {sibling}. Either move the key, "
                              f"or point fleet.settings.sopsSecretsFile there.")
                creds = creds or found
                break

    if not creds:
        console.print("[red]VERDICT[/red]  no credentials resolvable. Nothing to test against AWS.")
        sys.exit(1)

    # ── 3. does AWS accept them ────────────────────────────────────
    env = {**os.environ,
           "AWS_ACCESS_KEY_ID": creds["access_key_id"],
           "AWS_SECRET_ACCESS_KEY": creds["secret_access_key"],
           "AWS_DEFAULT_REGION": creds.get("region") or backend.get("region") or "us-east-1"}
    aws = shutil.which("aws") or None
    prefix = [aws] if aws else ["nix", "run", "--inputs-from", str(root), "nixpkgs#awscli2", "--"]

    r = subprocess.run(prefix + ["sts", "get-caller-identity", "--output", "json"],
                       capture_output=True, text=True, env=env, timeout=90)
    if r.returncode == 0:
        who = json.loads(r.stdout)
        console.print(f"[green]sts[/green]      accepted — {who.get('Arn')}")
    else:
        msg = (r.stderr or r.stdout).strip().splitlines()[-1:] or [""]
        console.print(f"[red]FAIL[/red]     STS rejected the credentials:\n         {msg[0]}")
        if "InvalidClientTokenId" in r.stderr or "InvalidAccessKeyId" in r.stderr:
            console.print("[dim]         The key ID is not known to AWS at all — deleted or "
                          "rotated upstream, not a permissions problem. Ask whoever owns the "
                          "account for a new one.[/dim]")
        console.print("[red]VERDICT[/red]  credentials resolve but are not valid.")
        sys.exit(1)

    # ── 4. bucket ──────────────────────────────────────────────────
    bucket = backend.get("bucket")
    r = subprocess.run(prefix + ["s3api", "head-bucket", "--bucket", bucket],
                       capture_output=True, text=True, env=env, timeout=90)
    if r.returncode == 0:
        console.print(f"[green]bucket[/green]   s3://{bucket} reachable and readable")
    else:
        last = (r.stderr or "").strip().splitlines()[-1:] or [""]
        console.print(f"[red]FAIL[/red]     s3://{bucket}: {last[0]}")
        console.print("[dim]         Credentials are valid, so this is the bucket or its "
                      "policy — not the key.[/dim]")
        ok = False

    console.print("[green]VERDICT[/green]  backend healthy" if ok
                  else "[red]VERDICT[/red]  backend NOT healthy — see above")
    sys.exit(0 if ok else 1)


# ── tf adopt: bring existing infrastructure under management ──────────
#
# CONFIG IS THE DRIVER. Resources are enumerated from the generated
# config.tf.json, and for each declared resource we work out what its
# real-world ID should be. Nothing undeclared can ever be pulled in — the
# blast radius is bounded by the manifest. (The inverse question, "what
# exists that I do NOT manage", is a separate verb by design; the two have
# very different risk profiles.)
#
# Every ID here is derived from fields the config already carries, so the
# derivation needs no network. It is then VERIFIED against the live
# provider before anything touches state: vmids are unique per cluster, but
# nothing guarantees the object at a vmid is the one this manifest means —
# a stale entry, a hand-edited number, or a vmid reused after a destroy all
# bind the wrong object. Deriving is cheap; being wrong is not.

# type -> (id_fn(name, body) -> str | None, verifiable)
# Only types whose import-ID FORMAT is certain live here. A guessed ID that
# happens to parse is the worst outcome available: it binds an address to
# some other real object, and the next apply "corrects" that object to match
# the config. Unknown types are reported as manual, never guessed.
_ADOPT_RESOLVERS: dict = {
    "proxmox_virtual_environment_container":
        (lambda n, b: f"{b['node_name']}/{b['vm_id']}" if b.get("vm_id") else None, True),
    "proxmox_virtual_environment_vm":
        (lambda n, b: f"{b['node_name']}/{b['vm_id']}" if b.get("vm_id") else None, True),
    "proxmox_virtual_environment_pool":
        (lambda n, b: b.get("pool_id"), False),
    "proxmox_virtual_environment_group":
        (lambda n, b: b.get("group_id"), False),
}

# No real-world counterpart: nothing to adopt, ever. Called out explicitly
# because they are silently RE-CREATED on the next apply — and a resource
# that generates a credential would rotate a live secret when it is.
_UNIMPORTABLE = {"terraform_data", "random_password", "random_id",
                 "random_string", "tls_private_key"}


def _unwrap(block):
    """terranix emits a resource body as either a dict or a 1-element list."""
    return block[0] if isinstance(block, list) else block


def _expected_hostname(name: str, body: dict) -> str:
    init = _unwrap(body.get("initialization") or {}) or {}
    return init.get("hostname") or name


def _verify_pve(vmid: int, node: str, expect: str) -> tuple[bool, str]:
    """Confirm the object at `vmid` is the one the config means."""
    try:
        from . import pve_api
        api = pve_api.get_client()
        cfg = pve_api.get_container_config(api, int(vmid), node=node)
    except BaseException as e:
        # BaseException, not Exception: pve_api exits the process when
        # PROXMOX_VE_* is unset, and a missing credential must degrade this
        # check rather than abort an otherwise useful dry run.
        msg = f"{type(e).__name__}: {str(e)[:100]}".strip()
        # "the object is not there" and "I could not look" are DIFFERENT
        # answers. Reporting the second as the first would tell an operator a
        # container is missing when the truth is that a credential is — and
        # the fix for each is nothing like the fix for the other.
        if any(s in str(e).lower() for s in ("does not exist", "not found", "no such")):
            return "absent", msg
        return "unverified", msg
    actual = (cfg or {}).get("hostname") or ""
    if not actual:
        return "unverified", "live object has no hostname field"
    if actual != expect:
        return "mismatch", f"live hostname is {actual!r}, config says {expect!r}"
    return "ok", actual


def _adopt_rows(wd: Path, verify: bool, in_state: set[str]) -> list[dict]:
    cfg = json.loads((wd / "config.tf.json").read_text())
    rows: list[dict] = []
    for rtype, entries in (cfg.get("resource") or {}).items():
        for name, block in entries.items():
            addr = f"{rtype}.{name}"
            body = _unwrap(block) or {}
            if rtype in _UNIMPORTABLE:
                rows.append({"addr": addr, "id": "", "state": "unimportable",
                             "note": "no real-world object — recreated on apply"})
                continue
            if addr in in_state:
                rows.append({"addr": addr, "id": "", "state": "in-state",
                             "note": "already managed"})
                continue
            resolver = _ADOPT_RESOLVERS.get(rtype)
            if resolver is None:
                rows.append({"addr": addr, "id": "", "state": "manual",
                             "note": f"no resolver for {rtype} — import by hand"})
                continue
            id_fn, verifiable = resolver
            try:
                rid = id_fn(name, body)
            except Exception as e:
                rid = None
                rows.append({"addr": addr, "id": "", "state": "manual",
                             "note": f"could not derive id: {e}"})
                continue
            if not rid:
                rows.append({"addr": addr, "id": "", "state": "manual",
                             "note": "id fields absent from config"})
                continue
            if verify and verifiable and "/" in str(rid):
                node, vmid = str(rid).split("/", 1)
                verdict, detail = _verify_pve(vmid, node, _expected_hostname(name, body))
                if verdict == "absent":
                    # The normal path for a resource that has not been
                    # provisioned yet — a plain apply will create it.
                    rows.append({"addr": addr, "id": rid, "state": "not-found",
                                 "note": "not provisioned yet — apply will create it"})
                    continue
                if verdict == "mismatch":
                    rows.append({"addr": addr, "id": rid, "state": "mismatch",
                                 "note": detail})
                    continue
                if verdict == "unverified":
                    rows.append({"addr": addr, "id": rid, "state": "unverified",
                                 "note": detail})
                    continue
            rows.append({"addr": addr, "id": rid, "state": "adopt",
                         "note": "verified" if (verify and verifiable) else "derived"})
    return sorted(rows, key=lambda r: r["addr"])


@tf_stacks.command("adopt")
@click.argument("scope")
@click.option("--target", "targets", multiple=True,
              help="Limit to these resource addresses (repeatable).")
@click.option("--yes", is_flag=True, help="Actually adopt. Without this, dry-run only.")
@click.option("--merge", is_flag=True,
              help="Allow adopting into a stack that already holds state.")
@click.option("--no-verify", is_flag=True,
              help="Skip the live provider check. Faster, and strictly more dangerous.")
def tf_adopt(scope: str, targets: tuple[str, ...], yes: bool,
             merge: bool, no_verify: bool) -> None:
    """Rebuild tofu state from live infrastructure for matched leaves.

    Disaster recovery, and what makes a local backend survivable: if state can
    be reconstructed from reality on demand, losing a state file stops being
    an emergency.

    Dry-run by default, and the dry-run deliberately does NOT need a working
    state backend — the moment you most want to know what is adoptable is
    when the backend is unreachable.

    Adoption makes state match reality BY DEFINITION, so any pre-existing
    drift silently becomes the new baseline. Read the dry-run table.
    """
    root = find_project_root()
    overall = 0
    for leaf in _resolve_scope(root, scope):
        console.print(f"── adopt {leaf} ──", style="bold cyan")
        wd = _stage_json(root, leaf)

        # State is only consulted when we can reach it. A dry-run against an
        # unreachable backend is still useful, so degrade rather than abort.
        in_state: set[str] = set()
        state_known = False
        if yes or (wd / ".terraform").is_dir():
            try:
                _ensure_init(wd)
                in_state = set(_state_addresses(wd))
                state_known = True
            except Exception:
                if yes:
                    console.print("[red]ERROR:[/red] cannot reach the state backend; "
                                  "adoption needs to write state. Try "
                                  "`fleet deploy tf backend-check`.")
                    sys.exit(1)
        if not state_known:
            console.print("[dim]state backend not consulted — 'in-state' cannot be "
                          "detected in this run[/dim]")

        rows = _adopt_rows(wd, verify=not no_verify, in_state=in_state)
        if targets:
            rows = [r for r in rows if r["addr"] in targets]
        if not rows:
            console.print("  nothing to consider")
            continue

        table = Table(show_header=True, header_style="bold")
        table.add_column("resource"); table.add_column("import id")
        table.add_column("status"); table.add_column("note")
        colour = {"adopt": "green", "in-state": "dim", "not-found": "yellow",
                  "mismatch": "red", "manual": "yellow", "unimportable": "red",
                  "unverified": "yellow"}
        for r in rows:
            c = colour.get(r["state"], "")
            table.add_row(r["addr"], r["id"], f"[{c}]{r['state']}[/{c}]" if c else r["state"],
                          r["note"])
        console.print(table)

        adoptable = [r for r in rows if r["state"] == "adopt"]
        mismatched = [r for r in rows if r["state"] == "mismatch"]
        unverified = [r for r in rows if r["state"] == "unverified"]
        if unverified:
            console.print(f"[yellow]WARNING:[/yellow] {len(unverified)} resource(s) could not be "
                          "checked against the live provider — that is not the same as absent. "
                          "They are excluded from adoption; fix provider access, or accept the "
                          "risk explicitly with --no-verify.")
        if mismatched:
            console.print(f"[red]REFUSING {leaf}:[/red] {len(mismatched)} resource(s) resolve to a "
                          "live object that is NOT the one the config describes. Adopting these "
                          "would bind the wrong object and the next apply would rewrite it. Fix "
                          "the manifest (or pass --target to adopt only the good ones).")
            overall = 1
            continue
        if not adoptable:
            console.print("  nothing adoptable")
            continue
        if not yes:
            console.print(f"[bold]dry run[/bold] — {len(adoptable)} resource(s) would be adopted. "
                          f"Re-run with --yes to write state.")
            continue
        if in_state and not merge:
            console.print(f"[red]REFUSING {leaf}:[/red] state already holds "
                          f"{len(in_state)} resource(s). Adopting into a non-empty state can "
                          "double-bind an address — pass --merge if that is what you mean.")
            overall = 1
            continue

        # Import BLOCKS, not N× `tofu import`: batched, and the plan becomes
        # the review artifact. Staged as a separate file so generated config
        # is never polluted, and removed on the way out.
        imports = [{"to": r["addr"], "id": r["id"]} for r in adoptable]
        imp = wd / "zz-adopt-import.tf.json"
        imp.write_text(json.dumps({"import": imports}, indent=2))
        try:
            backup = wd / "terraform.tfstate.pre-adopt"
            src = wd / "terraform.tfstate"
            if src.is_file():
                shutil.copy2(src, backup)
                console.print(f"[dim]state backed up → {backup}[/dim]")

            # THE GATE. apply performs the imports AND anything else in the
            # plan, so a wrong id does not fail loudly — it binds the wrong
            # object and the same apply "corrects" it. Refuse unless the plan
            # is imports and nothing else.
            plan = wd / "adopt.tfplan"
            r = subprocess.run(["tofu", "plan", "-input=false", "-out", str(plan)],
                               cwd=wd, capture_output=True, text=True)
            if r.returncode != 0:
                console.print(f"[red]ERROR:[/red] plan failed:\n{(r.stderr or '')[-800:]}")
                overall = 1
                continue
            show = subprocess.run(["tofu", "show", "-json", str(plan)],
                                  cwd=wd, capture_output=True, text=True)
            changes = [c for c in json.loads(show.stdout).get("resource_changes", [])
                       if set(c.get("change", {}).get("actions", [])) - {"no-op"}]
            if changes:
                console.print(f"[red]REFUSING {leaf}:[/red] the plan contains "
                              f"{len(changes)} resource change(s) beyond the imports:")
                for c in changes[:10]:
                    console.print(f"    {'/'.join(c['change']['actions'])}  {c['address']}")
                console.print("  Adoption must be a pure state operation. A non-empty plan means "
                              "an id is wrong or the config has drifted — resolve that first.")
                overall = 1
                continue
            r = subprocess.run(["tofu", "apply", "-input=false", str(plan)],
                               cwd=wd, capture_output=True, text=True)
            if r.returncode != 0:
                console.print(f"[red]ERROR:[/red] adopt failed:\n{(r.stderr or '')[-800:]}")
                overall = 1
                continue
            console.print(f"[green]adopted[/green] {len(adoptable)} resource(s) into {leaf}")
        finally:
            imp.unlink(missing_ok=True)
            (wd / "adopt.tfplan").unlink(missing_ok=True)

    sys.exit(overall)
