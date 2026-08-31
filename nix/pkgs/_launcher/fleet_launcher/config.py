"""fleet_launcher.config — the consumer-repo configuration surface.

fleetkit is environment-agnostic: every company/site-specific value the
CLI needs lives in **fleet.toml at the consumer repo root**, not in
code. This module finds and parses that file and hands out typed
accessors with actionable errors.

Design notes:
  * TOML (stdlib tomllib) and eval-free on purpose — the CLI must start
    fast; anything needing a Nix eval belongs in fleet.settings on the
    Nix side instead.
  * Values that already had universal conventions keep them as defaults
    (age key at ~/.ssh/sops-age.key, etc.) so a minimal fleet.toml stays
    minimal; company identifiers (name, domains, state bucket) have NO
    defaults and fail loudly when first used.

Minimal fleet.toml:

    [fleet]
    name = "acme"

    [domains]
    base = "acme.dev"            # public zone
    internal = "acme.lan"        # fleet-internal zone
    tailnet_suffix = "hs.acme.dev"

    [backend]
    bucket = "acme-tofu"         # tofu S3 state bucket
    region = "us-east-1"

    [sops]
    age_key_file = "~/.ssh/sops-age.key"
    secrets_file = "nix/secrets/secrets.yaml"

    [ssh]
    sysadmin_key_file = "~/.ssh/sysadmin-key"

    [cli]
    extensions_dir = "cli-ext"   # consumer command groups (see load_extensions)
"""
from __future__ import annotations

import os
import tomllib
from functools import lru_cache
from pathlib import Path
from typing import Any

import click

CONFIG_FILENAME = "fleet.toml"
ENV_CONFIG = "FLEET_CONFIG"  # explicit path override
ENV_ROOT = "FLEET_ROOT"      # explicit repo-root override


class FleetConfigError(click.ClickException):
    """Configuration problem the operator must fix in fleet.toml."""


def _search_upwards(start: Path) -> Path | None:
    for d in [start, *start.parents]:
        if (d / CONFIG_FILENAME).is_file():
            return d / CONFIG_FILENAME
    return None


@lru_cache(maxsize=1)
def config_path() -> Path | None:
    """Locate fleet.toml: $FLEET_CONFIG, else walk up from CWD."""
    if env := os.environ.get(ENV_CONFIG):
        p = Path(env).expanduser()
        if not p.is_file():
            raise FleetConfigError(f"$FLEET_CONFIG points at {p}, which does not exist")
        return p
    return _search_upwards(Path.cwd())


@lru_cache(maxsize=1)
def repo_root() -> Path:
    """Consumer repo root: $FLEET_ROOT, else the directory holding fleet.toml, else CWD."""
    if env := os.environ.get(ENV_ROOT):
        return Path(env).expanduser()
    if (p := config_path()) is not None:
        return p.parent
    return Path.cwd()


@lru_cache(maxsize=1)
def _raw() -> dict[str, Any]:
    p = config_path()
    if p is None:
        return {}
    with open(p, "rb") as fh:
        return tomllib.load(fh)


def get(dotted: str, default: Any = None) -> Any:
    """Fetch `section.key` with a default (None ⇒ optional)."""
    node: Any = _raw()
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node


def require(dotted: str, hint: str = "") -> Any:
    """Fetch `section.key` or die with a message telling the operator what to add."""
    val = get(dotted)
    if val is None:
        where = config_path() or f"{CONFIG_FILENAME} (not found — create it at your repo root)"
        raise FleetConfigError(
            f"missing `{dotted}` in {where}."
            + (f" {hint}" if hint else "")
            + " See fleet_launcher/config.py for the full schema."
        )
    return val


# ── Typed accessors (the parameter surface, front and center) ────────

def fleet_name() -> str:
    return require("fleet.name", "Short org/fleet slug, e.g. name = \"acme\".")

def base_domain() -> str:
    return require("domains.base", "Public zone, e.g. base = \"acme.dev\".")

def internal_domain() -> str:
    return require("domains.internal", "Fleet-internal zone, e.g. internal = \"acme.lan\".")

def tailnet_suffix() -> str:
    return require("domains.tailnet_suffix", "MagicDNS base domain, e.g. \"hs.acme.dev\".")

def backend_bucket() -> str:
    return require("backend.bucket", "Tofu S3 state bucket, e.g. bucket = \"acme-tofu\".")

def backend_region() -> str:
    return get("backend.region", "us-east-1")

def age_key_file() -> str:
    return os.path.expanduser(get("sops.age_key_file", "~/.ssh/sops-age.key"))

def secrets_file() -> Path:
    return repo_root() / get("sops.secrets_file", "nix/secrets/secrets.yaml")

def sysadmin_key_file() -> str:
    return os.path.expanduser(get("ssh.sysadmin_key_file", "~/.ssh/sysadmin-key"))

def ops_email() -> str:
    return get("fleet.ops_email", f"ops@{base_domain()}")


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
