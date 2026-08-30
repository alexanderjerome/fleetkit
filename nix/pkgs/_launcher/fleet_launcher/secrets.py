"""fleet secrets — SOPS secrets management.

Commands:
    edit              Open secrets in $EDITOR (standard sops workflow)
    edit --plaintext  Decrypt to plaintext YAML for IDE editing, re-encrypt on confirm
    keys list         List all secret key paths
    keys add          Add or update a key
    keys rm           Remove a key
    keys replace      Replace an existing key's value
    sync-infisical    Mirror secrets.yaml into Infisical (one-way, reconciling)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

import click
from rich.console import Console

console = Console()

DEFAULT_SECRETS_FILE = "nix/secrets/secrets.yaml"
PLAINTEXT_FILE = "nix/secrets/secrets.plaintext.yaml"


def _find_secrets_file() -> str:
    """Locate secrets.yaml relative to the repo root."""
    path = os.path.abspath(DEFAULT_SECRETS_FILE)
    if os.path.exists(path):
        return path
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        candidate = os.path.join(root, DEFAULT_SECRETS_FILE)
        if os.path.exists(candidate):
            return candidate
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return path


def _find_repo_root() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.getcwd()


def _require_sops() -> str:
    """Return sops binary path or exit with error."""
    sops = shutil.which("sops")
    if not sops:
        console.print("[red]ERROR:[/red] sops not found — run inside nix develop")
        sys.exit(1)
    return sops


def _ensure_age_key():
    """Ensure SOPS_AGE_KEY is set, loading from ~/.ssh/sops-age.key if needed."""
    if os.environ.get("SOPS_AGE_KEY"):
        return
    key_file = os.path.expanduser("~/.ssh/sops-age.key")
    if os.path.exists(key_file):
        with open(key_file) as f:
            os.environ["SOPS_AGE_KEY"] = f.read().strip()
    else:
        console.print("[yellow]Warning:[/yellow] SOPS_AGE_KEY not set and ~/.ssh/sops-age.key not found")


def _sops_decrypt_to_string(secrets_file: str) -> str:
    """Decrypt secrets file to a YAML string."""
    sops = _require_sops()
    _ensure_age_key()
    result = subprocess.run(
        [sops, "-d", secrets_file],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        console.print(f"[red]ERROR:[/red] sops decrypt failed: {result.stderr.strip()}")
        sys.exit(1)
    return result.stdout


def _sops_set(secrets_file: str, key_path: str, value: str):
    """Set a key in the secrets file using sops --set."""
    sops = _require_sops()
    _ensure_age_key()
    # sops --set expects a Python-literal-ish expression where the value is
    # parsed as JSON, e.g. '["key1"]["key2"] "value"'. Hand-quoting via
    # f-string corrupts any value containing newlines, double quotes, or
    # backslashes (e.g. PEM cert chains). json.dumps gives a properly
    # escaped JSON string literal that sops accepts byte-for-byte.
    parts = key_path.split("/")
    sops_path = "".join(f'["{p}"]' for p in parts)
    sops_expr = f'{sops_path} {json.dumps(value)}'
    result = subprocess.run(
        [sops, "--set", sops_expr, secrets_file],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        console.print(f"[red]ERROR:[/red] sops set failed: {result.stderr.strip()}")
        sys.exit(1)


def _sops_rm(secrets_file: str, key_path: str):
    """Remove a key from the secrets file using sops --set to null then cleanup."""
    # sops doesn't have a native --rm, so we decrypt, remove the key, re-encrypt
    sops = _require_sops()
    _ensure_age_key()

    import yaml
    plaintext = _sops_decrypt_to_string(secrets_file)
    data = yaml.safe_load(plaintext)

    # Navigate and remove the key
    parts = key_path.split("/")
    parent = data
    for part in parts[:-1]:
        if isinstance(parent, dict) and part in parent:
            parent = parent[part]
        else:
            console.print(f"[red]ERROR:[/red] Key path not found: {key_path}")
            sys.exit(1)

    if parts[-1] not in parent:
        console.print(f"[red]ERROR:[/red] Key not found: {key_path}")
        sys.exit(1)

    del parent[parts[-1]]

    # Clean up empty parent dicts
    # (don't bother, sops handles it)

    # Write back and re-encrypt. The temp file MUST live in the same
    # directory as secrets.yaml with a .yaml suffix so the repo's
    # .sops.yaml creation_rules match it — sops fails config matching
    # ("no matching creation rules") for a /tmp path before it even
    # considers explicit --age recipients (INFRA-197 fix; same pattern
    # as the `edit --plaintext` re-encrypt below). Matching the real
    # creation rule also re-encrypts for the CORRECT full recipient set
    # instead of whatever we could scrape from the old file's metadata.
    sf_dir = os.path.dirname(secrets_file) or "."
    with tempfile.NamedTemporaryFile(
        mode="w", dir=sf_dir, suffix=".yaml", delete=False
    ) as f:
        yaml.dump(data, f, default_flow_style=False)
        tmp_path = f.name

    try:
        result = subprocess.run(
            [sops, "-e", "-i", tmp_path],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            console.print(f"[red]ERROR:[/red] re-encrypt failed: {result.stderr.strip()}")
            sys.exit(1)
        shutil.move(tmp_path, secrets_file)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def _list_keys(data: dict, prefix: str = "") -> list[str]:
    """Recursively list all leaf key paths in a dict."""
    keys = []
    for k, v in sorted(data.items()):
        if k == "sops":  # Skip sops metadata
            continue
        path = f"{prefix}/{k}" if prefix else k
        if isinstance(v, dict):
            keys.extend(_list_keys(v, path))
        else:
            keys.append(path)
    return keys


# ─────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────

@click.group()
def secrets():
    """Manage SOPS-encrypted secrets.

    Operates on ``nix/secrets/secrets.yaml``. Requires ``sops`` and
    the SOPS age key (set via SOPS_AGE_KEY or ~/.ssh/sops-age.key).
    """


@secrets.command("edit")
@click.option("--file", "secrets_file", default=None,
              help="Override path to secrets.yaml.")
@click.option("--plaintext", is_flag=True,
              help="Decrypt to plaintext YAML for IDE editing.")
def secrets_edit(secrets_file: str | None, plaintext: bool):
    """Edit secrets in your terminal editor or IDE.

    Without --plaintext: standard sops workflow (decrypt → $EDITOR → re-encrypt).
    With --plaintext: decrypt to secrets.plaintext.yaml, edit in your IDE,
    then re-encrypt when you confirm.
    """
    sf = secrets_file or _find_secrets_file()
    sops = _require_sops()

    if not plaintext:
        _ensure_age_key()
        os.execvp(sops, [sops, sf])
    else:
        _ensure_age_key()
        root = _find_repo_root()
        pt_path = os.path.join(root, PLAINTEXT_FILE)

        # Decrypt to plaintext
        content = _sops_decrypt_to_string(sf)
        with open(pt_path, "w") as f:
            f.write(content)
        console.print(f"[green]Decrypted to:[/green] {pt_path}")
        console.print("[yellow]Edit this file in your IDE, then come back here.[/yellow]")
        console.print("")

        if click.confirm("Re-encrypt and save?", default=True):
            # Encrypt to a temp file FIRST; only replace secrets.yaml atomically
            # once sops succeeds. This keeps the original encrypted file intact
            # if re-encrypt fails (bad YAML, duplicate keys, missing age key, etc.).
            #
            # Temp file must:
            #   - end in .yaml so the `.sops.yaml` creation_rules regex matches
            #   - live in the same directory so relative .sops.yaml config applies
            sf_dir = os.path.dirname(sf) or "."
            with tempfile.NamedTemporaryFile(
                mode="w", dir=sf_dir, suffix=".yaml", delete=False
            ) as tf:
                with open(pt_path) as src:
                    shutil.copyfileobj(src, tf)
                tmp_path = tf.name
            try:
                result = subprocess.run(
                    [sops, "-e", "-i", tmp_path],
                    capture_output=True, text=True,
                )
                if result.returncode != 0:
                    console.print(f"[red]ERROR:[/red] re-encrypt failed: {result.stderr.strip()}")
                    console.print(f"[yellow]Plaintext file preserved at:[/yellow] {pt_path}")
                    console.print("[dim]secrets.yaml was NOT modified.[/dim]")
                    sys.exit(1)
                # Success — atomically replace secrets.yaml
                os.replace(tmp_path, sf)
                tmp_path = None  # prevent unlink in finally
            finally:
                if tmp_path and os.path.exists(tmp_path):
                    os.unlink(tmp_path)
            console.print("[green]Secrets re-encrypted.[/green]")
        else:
            console.print("[dim]Aborted. Plaintext file preserved.[/dim]")
            return

        # Clean up plaintext
        os.unlink(pt_path)
        console.print(f"[dim]Removed {pt_path}[/dim]")


@secrets.group("keys")
def keys():
    """Manage individual secret keys."""


@keys.command("list")
@click.option("--file", "secrets_file", default=None)
def keys_list(secrets_file: str | None):
    """List all secret key paths."""
    sf = secrets_file or _find_secrets_file()
    import yaml
    _ensure_age_key()
    plaintext = _sops_decrypt_to_string(sf)
    data = yaml.safe_load(plaintext)

    key_paths = _list_keys(data)
    console.print(f"[bold]{len(key_paths)} keys:[/bold]")
    for path in key_paths:
        console.print(f"  {path}")


@keys.command("add")
@click.argument("key_path")
@click.argument("value")
@click.option("--file", "secrets_file", default=None)
def keys_add(key_path: str, value: str, secrets_file: str | None):
    """Add or set a secret key.

    KEY_PATH is slash-separated (e.g., bitcoin/rpc_user).
    VALUE is the plaintext secret value.
    """
    sf = secrets_file or _find_secrets_file()
    _sops_set(sf, key_path, value)
    console.print(f"[green]Set:[/green] {key_path}")


@keys.command("rm")
@click.argument("key_path")
@click.option("--file", "secrets_file", default=None)
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation.")
def keys_rm(key_path: str, secrets_file: str | None, yes: bool):
    """Remove a secret key.

    KEY_PATH is slash-separated (e.g., analytics/ordinals_password).
    """
    sf = secrets_file or _find_secrets_file()
    if not yes:
        click.confirm(f"Remove key '{key_path}'?", abort=True)
    _sops_rm(sf, key_path)
    console.print(f"[green]Removed:[/green] {key_path}")


@keys.command("replace")
@click.argument("key_path")
@click.argument("new_value")
@click.option("--file", "secrets_file", default=None)
def keys_replace(key_path: str, new_value: str, secrets_file: str | None):
    """Replace an existing secret key's value.

    KEY_PATH is slash-separated (e.g., bitcoin/rpc_password).
    NEW_VALUE is the new plaintext value.
    """
    sf = secrets_file or _find_secrets_file()

    # Verify key exists first
    import yaml
    _ensure_age_key()
    plaintext = _sops_decrypt_to_string(sf)
    data = yaml.safe_load(plaintext)

    parts = key_path.split("/")
    node = data
    for part in parts:
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            console.print(f"[red]ERROR:[/red] Key not found: {key_path}")
            sys.exit(1)

    _sops_set(sf, key_path, new_value)
    console.print(f"[green]Replaced:[/green] {key_path}")


@secrets.command("sync-infisical")
@click.option("--file", "secrets_file", default=None,
              help="Override path to secrets.yaml.")
@click.option("--dry-run", is_flag=True,
              help="Compute diff against live Infisical state but do not apply.")
@click.option("--project-id", default=None,
              help="Override Infisical project ID (else read from SOPS).")
@click.option("--site-url", default=None,
              help="Override Infisical site URL (else read from SOPS or default).")
@click.option("--environment", default="prod", show_default=True,
              help="Infisical environment slug.")
def secrets_sync_infisical(
    secrets_file: str | None,
    dry_run: bool,
    project_id: str | None,
    site_url: str | None,
    environment: str,
):
    """Sync secrets.yaml → Infisical (one-way, reconciling).

    SOPS remains the source of truth. Infisical is a downstream read replica.
    Any direct edits in Infisical are overwritten on the next sync.

    Configuration lives under ``integrations.infisical`` in secrets.yaml:
      - sync_client_id      Universal Auth client ID for the sync machine identity
      - sync_client_secret  Universal Auth client secret
      - project_id          Infisical project ID (UUID)
      - site_url            Base URL of your Infisical instance (or --site-url)

    The /integrations/infisical and /services/infisical subtrees are excluded
    from the sync (self-referential — see infisical_sync.EXCLUDED_PATHS).
    """
    try:
        from infisical_sdk import InfisicalSDKClient
    except ImportError:
        console.print(
            "[red]ERROR:[/red] infisicalsdk not installed. "
            "Run `uv sync` inside `nix develop` to install."
        )
        sys.exit(1)

    import yaml
    from .infisical_sync import sync as run_sync

    sf = secrets_file or _find_secrets_file()
    _ensure_age_key()
    plaintext = _sops_decrypt_to_string(sf)
    data = yaml.safe_load(plaintext)

    cfg = (data.get("integrations", {}) or {}).get("infisical", {}) or {}
    client_id = cfg.get("sync_client_id")
    client_secret = cfg.get("sync_client_secret")
    resolved_site = site_url or cfg.get("site_url")
    resolved_project = project_id or cfg.get("project_id")

    missing = []
    if not client_id:
        missing.append("integrations/infisical/sync_client_id")
    if not client_secret:
        missing.append("integrations/infisical/sync_client_secret")
    if not resolved_project:
        missing.append("integrations/infisical/project_id (or --project-id)")
    if not resolved_site:
        missing.append("integrations/infisical/site_url (or --site-url)")
    if missing:
        console.print("[red]ERROR:[/red] missing required config:")
        for m in missing:
            console.print(f"  - {m}")
        console.print(
            "\n[dim]Create an Infisical project + machine identity, then add these "
            "via `sk devtools secrets keys add`.[/dim]"
        )
        sys.exit(1)

    console.print(f"[dim]Site:[/dim]        {resolved_site}")
    console.print(f"[dim]Project:[/dim]     {resolved_project}")
    console.print(f"[dim]Environment:[/dim] {environment}")
    console.print()

    client = InfisicalSDKClient(host=resolved_site)
    try:
        client.auth.universal_auth.login(
            client_id=client_id,
            client_secret=client_secret,
        )
    except Exception as e:
        console.print(f"[red]ERROR:[/red] Infisical auth failed: {e}")
        sys.exit(1)

    try:
        diff = run_sync(
            sops_data=data,
            client=client,
            project_id=resolved_project,
            environment=environment,
            dry_run=dry_run,
        )
    except Exception as e:
        console.print(f"[red]ERROR:[/red] sync failed: {e}")
        sys.exit(1)

    if dry_run and not diff.is_empty:
        console.print()
        console.print(
            "[dim]Dry run — no changes applied. "
            "Re-run without --dry-run to apply.[/dim]"
        )
