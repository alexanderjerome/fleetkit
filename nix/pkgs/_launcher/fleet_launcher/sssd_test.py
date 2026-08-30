"""fleet devtools sssd-test — end-to-end directory-auth probe (INFRA-199).

Logs into a fleet host as the `sssd-probe` service user using the SSH key
served FROM the directory (Authentik attributes.sshPublicKey → LDAP outpost
→ SSSD AuthorizedKeysCommand), with the private half decrypted from SOPS.
A green result proves the whole chain: Authentik user store up, LDAP outpost
authenticated + serving, SSSD online on the host, sshd consuming LDAP keys.

Failure modes it distinguishes:
  - key decrypt fails        → SOPS / age-key problem (local)
  - TCP connect fails        → host down / network
  - auth rejected            → chain broken somewhere between Authentik and
                               SSSD on the host (check `journalctl -u sssd`
                               there and `docker-authentik-ldap` on authentik)
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile

import click
from rich.console import Console

from ._util import find_project_root
from .secrets import _ensure_age_key, _require_sops

console = Console()

PROBE_USER = "sssd-probe"
SOPS_KEY_PATH = '["services"]["sssd-test"]["ssh_private_key"]'


def _resolve_host_ip(host_name: str) -> str:
    from .remote import _load_hosts

    hosts = _load_hosts()
    if host_name not in hosts:
        matches = [h for h in hosts if host_name in h]
        if len(matches) == 1:
            host_name = matches[0]
        else:
            console.print(f"[red]Host '{host_name}' not found.[/red]")
            sys.exit(1)
    host = hosts[host_name]
    ip = host.get("ip") or host.get("internal_ip", "")
    if not ip:
        console.print(f"[red]No reachable IP for '{host_name}'.[/red]")
        sys.exit(1)
    return ip


@click.command("sssd-test")
@click.argument("host")
def sssd_test(host: str):
    """Probe directory auth end-to-end by SSHing to HOST as sssd-probe.

    The probe user's key lives ONLY in Authentik (attributes.sshPublicKey);
    the host must fetch it via the LDAP outpost + SSSD to admit the login,
    so success verifies the entire fleet directory-auth chain.
    """
    sops = _require_sops()
    _ensure_age_key()
    root = find_project_root()
    secrets_file = str(root / "nix" / "secrets" / "secrets.yaml")

    result = subprocess.run(
        [sops, "-d", "--extract", SOPS_KEY_PATH, secrets_file],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout:
        console.print(f"[red]FAIL (local):[/red] could not decrypt probe key from SOPS: {result.stderr.strip()}")
        sys.exit(1)

    ip = _resolve_host_ip(host)
    console.print(f"[dim]probing {PROBE_USER}@{ip} ({host})…[/dim]")

    fd, key_path = tempfile.mkstemp(prefix="sssd-probe-", suffix=".key")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(result.stdout)
        os.chmod(key_path, 0o600)

        ssh = subprocess.run(
            [
                "ssh", "-i", key_path,
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=10",
                f"{PROBE_USER}@{ip}", "id",
            ],
            capture_output=True, text=True, timeout=45,
        )
    finally:
        os.unlink(key_path)

    if ssh.returncode == 0:
        console.print(f"[green]OK:[/green] directory auth chain healthy on {host}")
        console.print(f"  {ssh.stdout.strip()}")
    else:
        console.print(f"[red]FAIL:[/red] {PROBE_USER}@{host} rejected (rc={ssh.returncode})")
        if ssh.stderr.strip():
            console.print(f"  [dim]{ssh.stderr.strip().splitlines()[-1]}[/dim]")
        console.print(
            "  Chain to check: authentik up → docker-authentik-ldap serving "
            "(journalctl on authentik) → sssd online on the host "
            "(sssctl domain-status <sssd domain>) → user visible (getent passwd sssd-probe)")
        sys.exit(1)
