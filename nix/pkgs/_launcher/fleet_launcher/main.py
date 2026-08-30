"""fleet — unified CLI launcher for fleetkit-managed infrastructure.

Usage:
    fleet                  -> Trogon TUI (interactive command browser)
    fleet tui              -> Explicit Trogon TUI launch
    fleet deploy ...       -> Deployment pipelines (nixos / tf)
    fleet inventory ...    -> Host inventory management
    fleet remote ...       -> Run commands on fleet hosts via SSH or pct exec
    fleet bootstraps ...   -> One-time setup (hiro / pve / step-ca)
    fleet devtools ...     -> Secrets, utilities
"""
from __future__ import annotations

import click

# Trogon is a venv dependency (pyproject.toml), not a Nix package.
# Gracefully degrade if unavailable (e.g. running as a standalone Nix build).
try:
    from trogon import tui as _tui_decorator

    _HAS_TROGON = True

    # Trogon doesn't filter Click's UNSET sentinel, so required options
    # with no default show "Sentinel.UNSET" in the TUI form fields.
    # Patch the introspection to normalize UNSET → None.
    try:
        from click._utils import UNSET as _CLICK_UNSET
        import trogon.introspect as _trogon_introspect
        _orig_process = _trogon_introspect.MultiValueParamData.process_cli_option

        @classmethod  # type: ignore[misc]
        def _patched_process(cls, default):
            if default is _CLICK_UNSET:
                default = None
            return _orig_process(default)

        _trogon_introspect.MultiValueParamData.process_cli_option = _patched_process
    except (ImportError, AttributeError):
        pass  # Click internals changed — silently skip

except ImportError:
    _HAS_TROGON = False

    def _tui_decorator():  # type: ignore[misc]
        """No-op decorator when trogon is not installed."""
        def _identity(fn):
            return fn
        return _identity

# ── Local sub-groups ──────────────────────────────────────────
from fleet_launcher.deploy_group import deploy
from fleet_launcher.inventory import inventory as inventory_cli
from fleet_launcher.bootstraps_group import bootstraps
from fleet_launcher.devtools_group import devtools
from fleet_launcher.remote import remote
from fleet_launcher.sessions import sessions_cli
from fleet_launcher.pki_group import pki
from fleet_launcher.catalog_group import catalog


# ── Root group ────────────────────────────────────────────────

@_tui_decorator()
@click.group(invoke_without_command=True)
@click.version_option("0.3.0", prog_name="fleet")
@click.pass_context
def fleet(ctx: click.Context) -> None:
    """fleetkit infrastructure tool suite.

    Unified CLI for managing Proxmox LXC containers (via terranix/tofu),
    NixOS deployments (via Colmena), secrets, and developer tooling. Run
    without arguments to open the interactive TUI (requires Trogon), or
    use subcommands directly.

    \b
    Top-level groups:
      deploy       Deployment pipelines (nixos / tf)
      inventory    Host inventory generation and management
      remote       Run commands on fleet hosts (SSH or pct exec)
      bootstraps   One-time setup (hiro/pve/step-ca)
      devtools     Secrets, utilities
    """
    if ctx.invoked_subcommand is None:
        if _HAS_TROGON:
            # Trogon adds a "tui" command — invoke it automatically.
            ctx.invoke(fleet.commands["tui"])
        else:
            click.echo(ctx.get_help())


# ── Top-level groups ──────────────────────────────────────────

fleet.add_command(deploy)
fleet.add_command(inventory_cli, "inventory")
fleet.add_command(bootstraps)
fleet.add_command(devtools)
fleet.add_command(remote)
fleet.add_command(sessions_cli, "sessions")
fleet.add_command(pki)
fleet.add_command(catalog)

from .xoa_group import xoa as _xoa
fleet.add_command(_xoa)

# `sk pve` carries Proxmox VE host-management subcommands. The legacy
# install-nix / build-template ops in pve.py live alongside the newer
# `cluster` group for cluster lifecycle (pvecm create/add).
from .pve import pve as _pve
from .pve_cluster import cluster as _pve_cluster
_pve.add_command(_pve_cluster)
fleet.add_command(_pve)

# `sk pbs` — Proxmox Backup Server operator commands. Single-host
# product (no cluster), so no nested `cluster` group.
from .pbs import pbs as _pbs
fleet.add_command(_pbs)

# `sk s3` — Garage / object-store operator commands (mint-key, etc.).
from .s3 import s3 as _s3
fleet.add_command(_s3)



def _find_sops() -> str | None:
    """Locate the sops binary, checking PATH and common Nix store locations."""
    import shutil
    import os
    if sops := shutil.which("sops"):
        return sops
    for candidate in [
        os.path.expanduser("~/.nix-profile/bin/sops"),
        "/run/current-system/sw/bin/sops",
        "/nix/var/nix/profiles/default/bin/sops",
    ]:
        if os.path.isfile(candidate):
            return candidate
    return None


def _ensure_sops_age_key() -> None:
    """Set SOPS_AGE_KEY_FILE from ~/.ssh/sops-age.key if no age key is in env."""
    import os
    if os.environ.get("SOPS_AGE_KEY") or os.environ.get("SOPS_AGE_KEY_FILE"):
        return
    from .config import age_key_file
    key_file = age_key_file()
    if os.path.isfile(key_file):
        os.environ["SOPS_AGE_KEY_FILE"] = key_file


def _setup_env() -> None:
    """Load .env and populate the env vars our tools consume.

    Sets:
      - AWS_* (credentials for the tofu S3 state backend; bucket from fleet.toml)
      - PROXMOX_VE_* (terranix Proxmox provider credentials)

    All values come from SOPS (`nix/secrets/secrets.yaml`). Works both
    inside and outside `nix develop` — finds sops from common Nix store
    locations and loads the age key from ~/.ssh/sops-age.key if not set.
    """
    import os
    import subprocess

    try:
        from dotenv import load_dotenv
        from ._util import find_project_root
        root = find_project_root()
        env_file = root / ".env"
        if env_file.is_file():
            load_dotenv(env_file, override=False)
    except ImportError:
        from ._util import find_project_root
        root = find_project_root()

    _ensure_sops_age_key()
    sops = _find_sops()
    if not sops:
        return

    from .config import secrets_file as _cfg_secrets
    secrets_file = str(_cfg_secrets())

    # AWS credentials for the tofu S3 state backend.
    try:
        result = subprocess.run(
            [sops, "-d", "--extract", '["integrations"]["aws"]', secrets_file],
            capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            import yaml
            aws = yaml.safe_load(result.stdout)
            os.environ.setdefault("AWS_ACCESS_KEY_ID", aws["access_key_id"])
            os.environ.setdefault("AWS_SECRET_ACCESS_KEY", aws["secret_access_key"])
            os.environ.setdefault("AWS_DEFAULT_REGION", aws["region"])
    except Exception:
        pass

    # Proxmox provider credentials for terranix.
    try:
        result = subprocess.run(
            [sops, "-d", "--extract", '["integrations"]["proxmox"]', secrets_file],
            capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            import yaml
            pve = yaml.safe_load(result.stdout)
            mapping = {
                "endpoint": "PROXMOX_VE_ENDPOINT",
                "username": "PROXMOX_VE_USERNAME",
                "password": "PROXMOX_VE_PASSWORD",
            }
            for key, env_var in mapping.items():
                if key in pve:
                    os.environ.setdefault(env_var, str(pve[key]))
        os.environ.setdefault("PROXMOX_VE_INSECURE", "true")
    except Exception:
        pass

    # XCP-ng / XOA credentials — REST API for VM IP discovery during
    # `sk inventory generate` (XCP-ng VMs DHCP their NICs, so static IPs
    # aren't declarable in fleet.nix; we patch them in from live XOA).
    # SKRYBITDEV-618.
    try:
        result = subprocess.run(
            [sops, "-d", "--extract", '["integrations"]["xen-orchestra"]', secrets_file],
            capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            import yaml
            xoa = yaml.safe_load(result.stdout)
            # The SOPS-declared URL is wss://... (websocket) for the
            # Terraform provider. The REST API lives at https:// on the
            # same host, so convert here.
            ws_url = str(xoa.get("url", ""))
            if ws_url.startswith("wss://"):
                rest_url = "https://" + ws_url[len("wss://"):]
            elif ws_url.startswith("ws://"):
                rest_url = "http://" + ws_url[len("ws://"):]
            else:
                rest_url = ws_url
            rest_url = rest_url.rstrip("/")
            os.environ.setdefault("XOA_URL", rest_url)
            if "token" in xoa:
                os.environ.setdefault("XOA_TOKEN", str(xoa["token"]))
        os.environ.setdefault("XOA_INSECURE", "true")
    except Exception:
        pass


def _maybe_reexec_for_missing_tools() -> None:
    """Re-exec sk inside `nix develop` when required external tools are absent.

    INFRA-171: the devshell provides colmena/tofu but not `sk` (venv editable
    install); the venv provides `sk` but not colmena/tofu. Non-interactive
    contexts (CI, agents, tmux relaunch) routinely get one half only. When a
    deploy-family command is invoked and its wrapped tool is missing from
    PATH, transparently re-exec this same sk binary through `nix develop` so
    both halves are present.

    Opt-out: SK_NO_REEXEC=1. Loop guard: SK_REEXECED=1.
    """
    import os
    import shutil
    import sys

    if os.environ.get("SK_NO_REEXEC") == "1" or os.environ.get("SK_REEXECED") == "1":
        return

    argv = sys.argv[1:]
    if not argv or argv[0] != "deploy":
        return
    sub = argv[1] if len(argv) > 1 else ""
    needs = {"nixos": ["colmena"], "tf": ["tofu"]}.get(sub, ["colmena", "tofu"])
    missing = [t for t in needs if shutil.which(t) is None]
    if not missing:
        return
    if shutil.which("nix") is None:
        sys.stderr.write(
            f"sk: required tool(s) missing from PATH ({', '.join(missing)}) "
            f"and `nix` unavailable to re-enter the devshell — this will fail.\n")
        return

    from ._util import find_project_root, sk_executable
    root = find_project_root()
    sys.stderr.write(
        f"sk: {', '.join(missing)} not on PATH — re-entering devshell "
        f"(nix develop {root})…\n")
    os.environ["SK_REEXECED"] = "1"
    os.execvp("nix", ["nix", "develop", str(root), "--command",
                      sk_executable(), *argv])


def main() -> None:
    _maybe_reexec_for_missing_tools()
    _setup_env()
    # Consumer command groups from the repo's cli-ext/ (fleet.toml [cli]).
    from .config import load_extensions
    load_extensions(fleet)
    fleet()


if __name__ == "__main__":
    main()
