"""fleet_launcher.config — the consumer-repo configuration surface.

fleetkit is environment-agnostic: every company/site-specific value the
CLI needs is declared ONCE, in Nix (`fleet.settings`), and reaches this
module through **the catalog** — `.cache/fleet/catalog.json`, a generated
eval-free projection built by `nix build .#fleet-catalog` (ADR-097).

fleet.toml is GONE. It was "the eval-free twin of fleet.settings …
keep them in sync" — a manual-synchronization contract this module no
longer offers. A lingering fleet.toml warns loudly and is ignored.

Design notes:
  * Eval-free reads stay eval-free: the catalog is a cached artifact
    (the hosts.json pattern), auto-materialized when missing and
    refreshed when the repo's `nix/` tree hash changes. Set
    FLEET_NO_CATALOG_REFRESH=1 to forbid the refresh (offline/CI).
  * The dotted lookup paths (`domains.base`, `pve.install.serve_host`,
    …) are preserved verbatim from the toml era, so get()/require()
    call sites across the launcher are untouched.
  * Operator-MACHINE paths are not fleet facts and are not in the
    catalog: age key and sysadmin key resolve from FLEET_AGE_KEY_FILE /
    FLEET_SYSADMIN_KEY_FILE, falling back to the conventional
    ~/.ssh/sops-age.key / ~/.ssh/sysadmin-key.
  * Repo root: $FLEET_ROOT, else `git rev-parse --show-toplevel`, else
    walk up to a flake.nix, else CWD.
"""
from __future__ import annotations

import json
import os
import subprocess
from functools import lru_cache
from pathlib import Path
from typing import Any

import click

CATALOG_RELPATH = Path(".cache/fleet/catalog.json")
ENV_CATALOG = "FLEET_CATALOG"            # explicit catalog-path override
ENV_ROOT = "FLEET_ROOT"                  # explicit repo-root override
ENV_NO_REFRESH = "FLEET_NO_CATALOG_REFRESH"
ENV_AGE_KEY = "FLEET_AGE_KEY_FILE"
ENV_SYSADMIN_KEY = "FLEET_SYSADMIN_KEY_FILE"


class FleetConfigError(click.ClickException):
    """Configuration problem the operator must fix in the fleet's Nix config."""


@lru_cache(maxsize=1)
def repo_root() -> Path:
    """Consumer repo root: $FLEET_ROOT → git toplevel → walk-up to flake.nix → CWD."""
    if env := os.environ.get(ENV_ROOT):
        return Path(env).expanduser()
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        pass
    for d in [Path.cwd(), *Path.cwd().parents]:
        if (d / "flake.nix").is_file():
            return d
    return Path.cwd()


def _warn(msg: str) -> None:
    click.echo(f"warning: {msg}", err=True)


def _source_tree_hash(root: Path) -> str | None:
    """Cheap staleness fingerprint: the git tree hash of nix/ at HEAD.

    Dirty (uncommitted) nix/ edits do not bump it — the same accepted
    blind spot hosts.json has always had; ops commands refresh both.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD:nix"],
            cwd=root, capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip() if out.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _materialize_catalog(root: Path, dest: Path) -> bool:
    """`nix build .#fleet-catalog` and copy the result to dest. True on success."""
    try:
        result = subprocess.run(
            ["nix", "build", ".#fleet-catalog", "--no-link", "--print-out-paths"],
            cwd=root, capture_output=True, text=True, timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _warn(f"could not build fleet-catalog: {exc}")
        return False
    if result.returncode != 0:
        _warn(f"nix build .#fleet-catalog failed:\n{result.stderr.strip()}")
        return False
    store_path = Path(result.stdout.strip().splitlines()[-1])
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".json.tmp")
    tmp.write_text(store_path.read_text())
    tmp.replace(dest)
    if (src := _source_tree_hash(root)) is not None:
        dest.with_suffix(".src").write_text(src + "\n")
    return True


@lru_cache(maxsize=1)
def catalog_path() -> Path | None:
    """Locate (and if needed materialize/refresh) the catalog JSON."""
    if env := os.environ.get(ENV_CATALOG):
        p = Path(env).expanduser()
        if not p.is_file():
            raise FleetConfigError(f"$FLEET_CATALOG points at {p}, which does not exist")
        return p

    root = repo_root()

    # ADR-095 → ADR-097 migration: loud, no silent fallback.
    if (root / "fleet.toml").is_file():
        _warn("fleet.toml is ignored since ADR-097 — its values live in "
              "fleet.settings (Nix) now; delete the file.")
    if os.environ.get("FLEET_CONFIG"):
        _warn("$FLEET_CONFIG is ignored since ADR-097 — use $FLEET_CATALOG "
              "to point at a catalog JSON, or $FLEET_ROOT for the repo.")

    dest = root / CATALOG_RELPATH
    if not (root / "flake.nix").is_file():
        return dest if dest.is_file() else None

    refresh_allowed = not os.environ.get(ENV_NO_REFRESH)
    if not dest.is_file():
        if not refresh_allowed:
            return None
        click.echo("Materializing .cache/fleet/catalog.json (first run)…", err=True)
        return dest if _materialize_catalog(root, dest) else None

    # Refresh when the nix/ tree changed since generation.
    src_file = dest.with_suffix(".src")
    recorded = src_file.read_text().strip() if src_file.is_file() else None
    current = _source_tree_hash(root)
    if current is not None and recorded != current:
        if refresh_allowed:
            click.echo("fleet catalog stale (nix/ changed) — refreshing…", err=True)
            _materialize_catalog(root, dest)  # failure warned; stale copy still used
        else:
            _warn("fleet catalog is stale (nix/ changed) and "
                  f"${ENV_NO_REFRESH} forbids refreshing it")
    return dest


@lru_cache(maxsize=1)
def _raw() -> dict[str, Any]:
    p = catalog_path()
    if p is None:
        return {}
    with open(p, "rb") as fh:
        return json.load(fh)


def get(dotted: str, default: Any = None) -> Any:
    """Fetch `section.key` with a default (None ⇒ optional). Catalog nulls
    (Nix `null` for an unset optional) fall through to the default too."""
    node: Any = _raw()
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return default if node is None else node


def require(dotted: str, hint: str = "") -> Any:
    """Fetch `section.key` or die telling the operator what to declare."""
    val = get(dotted)
    if val is None:
        where = catalog_path() or ".cache/fleet/catalog.json (not materialized — is `nix build .#fleet-catalog` green?)"
        raise FleetConfigError(
            f"missing `{dotted}` in {where}."
            + (f" {hint}" if hint else "")
            + " Declare it in fleet.settings (Nix) — see fleetkit nix/fleet/settings.nix."
        )
    return val


# ── Typed accessors (the parameter surface, front and center) ────────

def fleet_name() -> str:
    return require("fleet.name", "Short org/fleet slug: fleet.settings.name.")

def base_domain() -> str:
    return require("domains.base", "Public zone: fleet.settings.domain.base.")

def internal_domain() -> str:
    return require("domains.internal", "Fleet-internal zone: fleet.settings.domain.internal.")

def tailnet_suffix() -> str:
    return require("domains.tailnet_suffix", "MagicDNS base domain: fleet.settings.domain.tailnetSuffix.")

def backend_bucket() -> str:
    return require("backend.bucket", "Tofu S3 state bucket: fleet.settings.backend.bucket.")

def backend_region() -> str:
    return get("backend.region", "us-east-1")

def age_key_file() -> str:
    return os.path.expanduser(os.environ.get(ENV_AGE_KEY, "~/.ssh/sops-age.key"))

def secrets_file() -> Path:
    return repo_root() / get("sops.secrets_file", "nix/secrets/secrets.yaml")

def integrations_file() -> Path:
    """SOPS file holding the `integrations.*` tree — provider credentials.

    A fleet that splits its SOPS store per resource group keeps provider
    tokens (aws, proxmox, cloudflare, xen-orchestra) apart from the file
    NixOS hosts default to. `fleet.settings.tfSopsFile` names that file for
    the terranix layer; the CLI reads the SAME tree for the SAME credentials,
    so it follows the same setting rather than keeping a second opinion.

    Falls back to `secrets_file()` when unset, which is the single-file case.
    """
    tf = get("tf.sops_file") or get("sops.tf_file")
    return (repo_root() / tf) if tf else secrets_file()

def sysadmin_key_file() -> str:
    return os.path.expanduser(os.environ.get(ENV_SYSADMIN_KEY, "~/.ssh/sysadmin-key"))

def ops_email() -> str:
    return get("fleet.ops_email") or f"ops@{base_domain()}"


# ── Consumer CLI extensions ──────────────────────────────────────────

def load_extensions(root_group: click.Group) -> None:
    """Register consumer command groups onto the root CLI.

    Every `*.py` in `[cli].extensions_dir` (default `cli-ext/`, relative
    to the repo root) is imported. Each file may expose either or both of:

      COMMANDS = [cmd, ...]            added to the ROOT group
                                       -> `fleet <cmd>`
      ATTACH   = {"devtools": [cmd]}   added to an EXISTING framework group
                                       -> `fleet devtools <cmd>`

    This is how a consumer repo keeps company-specific tooling (app test
    harnesses, product-specific operator commands such as a pricing-catalog
    CLI, …) on the same `fleet` entry point without forking the framework.

    Neither a broken extension file nor an ATTACH naming a group that does
    not exist is fatal — both warn and continue. A consumer's tooling must
    never be able to brick the deployment CLI.
    """
    ext_dir = repo_root() / get("cli.extensions_dir", "cli-ext")
    if not ext_dir.is_dir():
        return
    import importlib.util
    for py in sorted(ext_dir.glob("*.py")):
        if py.name.startswith("_"):
            continue
        spec = importlib.util.spec_from_file_location(f"fleet_ext.{py.stem}", py)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except Exception as exc:  # noqa: BLE001 — a broken extension must not brick the CLI
            click.echo(f"warning: skipping CLI extension {py.name}: {exc}", err=True)
            continue
        for cmd in getattr(module, "COMMANDS", []):
            root_group.add_command(cmd)

        # ATTACH lets an extension hang commands off an EXISTING framework
        # group rather than the root — `{"devtools": [cmd, ...]}` puts them
        # under `fleet devtools <cmd>`. Without this a consumer can only add
        # top-level groups, which forces unrelated company tooling up into
        # the root namespace purely because the mechanism could not reach a
        # subgroup. Found porting Skrybit's CLI (INFRA-227): 8 of its 12
        # extension commands belonged under devtools.
        #
        # An unknown parent is a warning, not a crash: the same rule as a
        # broken extension file — consumer tooling must not brick the CLI.
        for parent_name, cmds in getattr(module, "ATTACH", {}).items():
            parent = root_group.get_command(None, parent_name)  # type: ignore[arg-type]
            if not isinstance(parent, click.Group):
                click.echo(
                    f"warning: {py.name} wants to attach to '{parent_name}', "
                    f"which is not a command group on this CLI",
                    err=True,
                )
                continue
            for cmd in cmds:
                parent.add_command(cmd)
