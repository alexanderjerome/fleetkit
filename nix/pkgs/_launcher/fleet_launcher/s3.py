"""fleet s3 — Garage operator helpers (single-node `s3` host).

Pairs with the declarative bootstrap in nix/modules/infra/services/garage/bootstrap.nix:
the bootstrap creates the buckets, this CLI mints per-consumer access
keys + saves them to SOPS. Keys live separately from buckets because
each consumer mints its own + drops the secret into its own SOPS path
(atticd → services/attic/garage_*, pgbackrest → integrations/pgbackrest/
garage_*, PBS → integrations/pbs/garage/*), and re-deriving them at the
producer side would couple s3.nix to its consumers.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir

console = Console()

GARAGE_ENV_PATH = "/run/secrets/rendered/garage-env"


def _load_hosts() -> dict:
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found — run `fleet inventory generate` first")
        sys.exit(1)
    with open(hosts_file) as f:
        return json.load(f)


def _s3_host(hosts: dict) -> tuple[str, dict]:
    """Find the s3 host (tag = s3) in fleet.compute."""
    matches = [(n, m) for n, m in hosts.items() if "s3" in m.get("tags", [])]
    if not matches:
        console.print("[red]ERROR:[/red] no host carries the 's3' tag in fleet.compute")
        sys.exit(1)
    if len(matches) > 1:
        names = ", ".join(n for n, _ in matches)
        console.print(f"[red]ERROR:[/red] multiple s3-host tagged: {names}")
        sys.exit(1)
    return matches[0]


def _ssh_garage(ip: str, cmd: str, *, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run a `garage <subcommand>` on s3 with the RPC env loaded."""
    full = f". {GARAGE_ENV_PATH} && {cmd}"
    ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={timeout}",
        "-o", "BatchMode=yes",
        f"root@{ip}",
        full,
    ]
    return subprocess.run(ssh_cmd, capture_output=True, text=True, check=False)


def _parse_key_info(text: str) -> tuple[str, str]:
    """Extract (key_id, secret) from `garage key create|info --show-secret` output.

    The format is:
      Key name: <name>
      Key ID: GK<24-hex>
      Secret key: <64-hex>
      Can create buckets: ...
      ...
    """
    key_id = None
    secret = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Key ID:"):
            key_id = line.split(":", 1)[1].strip()
        elif line.startswith("Secret key:"):
            secret = line.split(":", 1)[1].strip()
    if not key_id or not secret:
        raise ValueError(f"could not parse key id/secret from garage output:\n{text}")
    return key_id, secret


@click.group("s3")
def s3() -> None:
    """Garage / S3 operator commands."""


@s3.command("mint-key")
@click.argument("key_name")
@click.argument("bucket")
@click.option("--sops-prefix", required=True,
              help="SOPS path prefix for the saved credentials (e.g. integrations/pbs/garage).")
@click.option("--rotate", is_flag=True,
              help="If the key already exists on Garage, delete + recreate to capture a fresh secret.")
@click.option("--endpoint-host",
              help="Hostname to write into the saved endpoint URL (default: s3's fleet IP).")
@click.option("--region", default="us-east-1", show_default=True,
              help="S3 region label written to SOPS (Garage doesn't enforce it but clients do).")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation.")
def mint_key(key_name: str, bucket: str, sops_prefix: str, rotate: bool,
             endpoint_host: str | None, region: str, yes: bool) -> None:
    """Mint a Garage access key for BUCKET and save credentials to SOPS.

    Idempotent on re-run when --rotate is set (old key is deleted; new one
    minted with the same name). Without --rotate, an existing key is an
    error so we never silently break an active consumer.

    Saved SOPS layout (under --sops-prefix):
      <prefix>/access_key_id     GK… string
      <prefix>/secret_access_key 64-hex string (only ever readable once)
      <prefix>/endpoint          http://<host>:3900
      <prefix>/bucket            bucket name (verbatim)
      <prefix>/region            S3 region label

    The bucket must already exist (declared in services.garage layout or
    via infra.garage-bootstrap.buckets). Grants are --read --write on the
    declared bucket; no --owner — owner = the bucket-creator (Garage's
    default key on bootstrap).
    """
    hosts = _load_hosts()
    name, meta = _s3_host(hosts)
    ip = meta["internal_ip"]
    endpoint = f"http://{endpoint_host or ip}:3900"

    console.print(f"[bold]s3 host:[/bold]  {name} ({ip})")
    console.print(f"[bold]Key:[/bold]      {key_name}")
    console.print(f"[bold]Bucket:[/bold]   {bucket}")
    console.print(f"[bold]Endpoint:[/bold] {endpoint}")
    console.print(f"[bold]SOPS:[/bold]     {sops_prefix}/{{access_key_id,secret_access_key,endpoint,bucket,region}}")
    console.print()

    if not yes and not click.confirm("Mint + save?", default=False):
        console.print("aborted")
        sys.exit(1)

    # ── 1. existence check ──────────────────────────────────
    res = _ssh_garage(ip, f"garage key info {key_name}")
    key_exists = res.returncode == 0 and "Key ID:" in res.stdout
    if key_exists and not rotate:
        console.print(
            f"[red]ERROR:[/red] key '{key_name}' already exists on Garage. "
            "Re-run with --rotate to delete + recreate (will break any existing consumer using the old secret)."
        )
        sys.exit(1)

    # ── 2. delete if rotating ───────────────────────────────
    if key_exists and rotate:
        console.print(f"  rotating: deleting existing key '{key_name}'...", style="dim")
        res = _ssh_garage(ip, f"garage key delete {key_name} --yes")
        if res.returncode != 0:
            console.print(f"[red]FAILED to delete[/]: {res.stderr.strip()}")
            sys.exit(res.returncode)

    # ── 3. create key (captures secret — only chance) ───────
    console.print(f"  creating key '{key_name}'...", style="dim")
    res = _ssh_garage(ip, f"garage key create {key_name}")
    if res.returncode != 0:
        console.print(f"[red]FAILED on garage key create[/]: {res.stderr.strip()}")
        sys.exit(res.returncode)

    try:
        key_id, secret = _parse_key_info(res.stdout)
    except ValueError as e:
        console.print(f"[red]parse error[/]: {e}")
        sys.exit(1)
    console.print(f"  ✓ key minted: [cyan]{key_id}[/]")

    # ── 4. grant read+write on the bucket ───────────────────
    console.print(f"  granting read+write on bucket '{bucket}'...", style="dim")
    res = _ssh_garage(ip, f"garage bucket allow {bucket} --read --write --key {key_name}")
    if res.returncode != 0:
        console.print(f"[red]FAILED on bucket allow[/]: {res.stderr.strip()}")
        sys.exit(res.returncode)
    console.print(f"  ✓ granted")

    # ── 5. save to SOPS ─────────────────────────────────────
    payload = [
        (f"{sops_prefix}/access_key_id", key_id),
        (f"{sops_prefix}/secret_access_key", secret),
        (f"{sops_prefix}/endpoint", endpoint),
        (f"{sops_prefix}/bucket", bucket),
        (f"{sops_prefix}/region", region),
    ]
    for path, value in payload:
        sk_res = subprocess.run(
            ["sk", "devtools", "secrets", "keys", "add", path, value],
            capture_output=True, text=True, check=False,
        )
        if sk_res.returncode != 0:
            console.print(f"[red]Failed to save {path}[/]: {sk_res.stderr.strip()}")
            sys.exit(sk_res.returncode)
        console.print(f"  ✓ wrote SOPS: [cyan]{path}[/]")

    console.print()
    console.print("[green]Key minted + saved to SOPS.[/]")
    console.print()
    console.print("[bold]Reference from a consumer:[/bold]")
    console.print(f'  secrets.access_key_id     = "{sops_prefix}/access_key_id";')
    console.print(f'  secrets.secret_access_key = "{sops_prefix}/secret_access_key";')
    console.print(f'  secrets.endpoint          = "{sops_prefix}/endpoint";')
