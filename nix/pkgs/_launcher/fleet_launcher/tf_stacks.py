"""fleet tf — Terranix/OpenTofu stack lifecycle (SKRYBITDEV-599).

Scope is `<env>.<stack>` dot-paths resolved by prefix-match against the
auto-generated leaf stack list. Examples:

    sk deploy tf list
    sk deploy tf apply platform.bootstrap
    sk deploy tf apply platform                    # every platform.* leaf
    sk deploy tf apply all                         # every leaf
    sk deploy tf preview dev.bitcoin.mainnet
    sk deploy tf destroy dev.apps.testnet --target api-testnet
    sk deploy tf import platform.bootstrap proxmox_virtual_environment_pool.pool-core core

Every operation flows through `nix build .#tf-<env>-<stack-dashed>` to
regenerate config.tf.json from the unified fleet, then runs
`tofu -chdir=.tf/<env>-<stack-dashed>` in the repo-local workdir.

Destruction safety:
- `destroy` parses config.tf.json and refuses to run if any `--target`
  resolves to a block with `lifecycle.prevent_destroy = true`. The
  unprotect workflow is printed.
- `--target-dependents` doesn't exist in OpenTofu by design (-target is
  upward-only), so the SKRYBITDEV-598 footgun can't recur.
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
# fleet.compute entries since SKRYBITDEV-628), nix/tf (emitters; was
# nix/terranix pre-628) and nix/lib (emitter helpers). False positives
# (rebuilding when output would be identical) are cheap because Nix
# dedups in its store; false negatives would be incorrect, so the
# fingerprint stays conservative. INFRA-42 fixed a false negative: the
# old list still hashed the removed nix/terranix dir and missed
# nix/hosts entirely, so host-file edits reused stale config.tf.json.

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
        console.print("Unprotect workflow (SKRYBITDEV-598 / ADR-014/015):")
        console.print("  1. Edit the fleet entry in nix/fleet/{fleet,resources}.nix: set protect = false")
        console.print("     (OR remove the stateful tag that forced it via destruction_policy)")
        console.print("  2. `sk deploy tf apply <scope>` — lifecycle.prevent_destroy is removed")
        console.print("  3. `sk deploy tf destroy <scope> --target <name>`")
        console.print("  4. Re-enable protect=true before the next apply")
        sys.exit(1)


# ── CLI ──────────────────────────────────────────────────────────────

@click.group("tf")
def tf_stacks() -> None:
    """Terranix/OpenTofu stack lifecycle (SKRYBITDEV-599).

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
              help="After apply, refresh .cache/sk/hosts.json from XOA (qemu-guest-agent "
                   "IP discovery for XCP-ng VMs). Only triggers on env=infra leaves; "
                   "proxmox applies skip the refresh regardless.")
def tf_apply(scope: str, target: tuple[str, ...], yes: bool, parallelism: int, inventory: bool) -> None:
    """tofu apply for leaves matching SCOPE.

    Post-apply inventory refresh policy:

      - env=infra (XCP-ng/XOA) leaves: refresh .cache/sk/hosts.json so
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
        console.print("[dim]── refreshing .cache/sk/hosts.json from XOA ──[/dim]")
        try:
            from .inventory import generate_hosts_json
            generate_hosts_json(quiet=True)
            console.print("[green]✓[/green] inventory refreshed")
            console.print(
                "[dim]Tip: if a tier-0 VM's IP shows as empty, the guest agent "
                "may not have reported yet — re-run [bold]sk inventory generate[/bold] "
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
      sk deploy tf import platform.bootstrap \\
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
      sk deploy tf state-mv platform.bootstrap \\
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
    `tofu state mv`-before-apply dance done for observe→grafana and
    api-mainnet→dash.

    This is only the STATE half of a rename. Full workflow:

      1. Rename the fleet entry yourself: the attr key in
         nix/hosts/<provider>/<old>.nix, the hostsRegistry key, and the
         file → <new>.nix.
      2. sk deploy tf rekey <stack> <old> <new>     ← you are here
      3. sk deploy tf apply <stack> --target <type>.<new>
         (the PVE guest name/hostname updates in place)

    Touches tofu state only — never running infra, and never the Nix
    files (do step 1 first). The trailing plan flags a destroy/replace if
    the rename was incomplete (a sibling wasn't moved) or an attr drifted.

    Example:
      sk deploy tf rekey platform.core observe grafana
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
                      "`sk deploy tf state-mv` manually.[/dim]")

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
                  f"[bold]sk deploy tf apply {leaf} --target {new_addr_types[0]}[/bold] to land "
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
@click.argument("scope", default="")
@click.option("--out-dir", default="state-export", show_default=True,
              type=click.Path(file_okay=False),
              help="Directory to write <leaf>.tfstate.json files into.")
def tf_state_export(scope: str, out_dir: str) -> None:
    """Export live tfstate JSON for SCOPE (or the whole fleet) to files.

    SCOPE is a leaf id or prefix (empty = every leaf stack). One
    <env>-<stack>.tfstate.json per leaf lands in --out-dir, plus a
    manifest.json listing what was exported. Read-only: this is
    `tofu state pull` per stack, nothing is modified.
    """
    import json as _json

    root = find_project_root()
    leaves = _resolve_scope(root, scope) if scope else _resolve_scope(root, "")
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
