"""fleet bootstraps step-ca — One-time PKI bootstrap for step-ca.

SSHes into the netgate host and runs `step ca init` to generate the
root CA and intermediate certificates that step-ca needs to start.

Requires:
  - netgate container running and SSH-reachable
  - SOPS secrets.yaml with step-ca/intermediate-password
  - .cache/fleet/hosts.json with netgate entry
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir

console = Console()


def _sops_decrypt(secrets_file: str, key_path: str) -> str:
    """Decrypt a single key from SOPS."""
    result = subprocess.run(
        ["sops", "-d", "--extract", key_path, secrets_file],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        console.print(f"[red]ERROR:[/red] Failed to decrypt {key_path}: {result.stderr.strip()}")
        sys.exit(1)
    return result.stdout.strip()


def _get_netgate_ip() -> str:
    """Get netgate's SSH-reachable IP from hosts.json."""
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found — run `fleet inventory generate` first")
        sys.exit(1)

    hosts = json.loads(hosts_file.read_text())
    netgate = hosts.get("netgate", {})
    ip = netgate.get("ip")
    if not ip:
        console.print("[red]ERROR:[/red] netgate not found in hosts.json")
        sys.exit(1)
    return ip


def _ssh_run(ip: str, cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command on netgate via SSH."""
    result = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no",
         f"root@{ip}", cmd],
        capture_output=True, text=True,
    )
    if check and result.returncode != 0:
        console.print(f"[red]ERROR:[/red] SSH command failed:\n{result.stderr.strip()}")
        sys.exit(1)
    return result


@click.command("step-ca")
@click.option("--ca-name", default="Fleet Internal CA", help="Name for the CA")
@click.option("--dns", default=None, show_default="ca.<domains.internal>,localhost", help="DNS names for the CA cert")
@click.option("--address", default="0.0.0.0:9000", help="Listen address for step-ca")
@click.option("--provisioner", default="acme", help="Default provisioner name")
@click.option("--data-dir", default="/var/lib/step-ca", help="step-ca data directory on netgate")
@click.option("--force", is_flag=True, help="Re-initialize even if certs already exist")
def bootstrap_step_ca(ca_name, dns, address, provisioner, data_dir, force):
    """Bootstrap step-ca PKI on netgate (one-time).

    Generates root CA + intermediate certificates so step-ca can
    start serving ACME certificates for internal services.
    """
    root = find_project_root()
    secrets_file = str(root / "nix" / "secrets" / "secrets.yaml")

    # 1. Resolve secrets
    console.print("[bold]Resolving secrets from SOPS...[/bold]")
    intermediate_password = _sops_decrypt(secrets_file, '["step-ca"]["intermediate-password"]')
    console.print("  Intermediate password: [green]OK[/green]")

    # 2. Find netgate
    ip = _get_netgate_ip()
    console.print(f"  Netgate IP: [cyan]{ip}[/cyan]")

    # 3. Check SSH connectivity
    console.print("[bold]Checking SSH connectivity...[/bold]")
    check = _ssh_run(ip, "echo SSH_OK", check=False)
    if "SSH_OK" not in (check.stdout or ""):
        console.print(f"[red]ERROR:[/red] Cannot SSH to netgate at {ip}")
        sys.exit(1)
    console.print("  SSH: [green]connected[/green]")

    # 4. Check if already bootstrapped
    if not force:
        check = _ssh_run(ip, f"test -f {data_dir}/certs/root_ca.crt && echo EXISTS || echo MISSING", check=False)
        if "EXISTS" in (check.stdout or ""):
            console.print("[green]step-ca already bootstrapped[/green] (certs exist). Use --force to re-init.")
            return

    # 5. Ensure data dirs exist with correct ownership
    console.print("[bold]Preparing data directories...[/bold]")
    _ssh_run(ip, f"mkdir -p {data_dir}/certs {data_dir}/secrets {data_dir}/db && chown -R step-ca:step-ca {data_dir}")

    # 6. Write intermediate password to a temp file on netgate
    console.print("[bold]Bootstrapping step-ca PKI...[/bold]")
    _ssh_run(ip, f"umask 077 && echo '{intermediate_password}' > /tmp/.step-ca-pw && chown step-ca:step-ca /tmp/.step-ca-pw")

    # 7. Run step ca init as the step-ca user
    init_cmd = (
        f"sudo -u step-ca step ca init"
        f" --name='{ca_name}'"
        f" --dns='{dns}'"
        f" --address='{address}'"
        f" --provisioner='{provisioner}'"
        f" --password-file=/tmp/.step-ca-pw"
        f" --deployment-type=standalone"
        f" --path={data_dir}"
    )
    console.print(f"  Running: [dim]step ca init[/dim]")
    result = _ssh_run(ip, init_cmd, check=False)

    # Clean up password file regardless of outcome
    _ssh_run(ip, "rm -f /tmp/.step-ca-pw", check=False)

    if result.returncode != 0:
        console.print(f"[red]ERROR:[/red] step ca init failed:\n{result.stderr.strip()}")
        if result.stdout.strip():
            console.print(f"[dim]{result.stdout.strip()}[/dim]")
        sys.exit(1)

    console.print(f"[green]PKI initialized successfully[/green]")
    if result.stdout.strip():
        # Show the fingerprint and root cert info
        for line in result.stdout.strip().split("\n"):
            console.print(f"  [dim]{line}[/dim]")

    # 8. Restart step-ca service
    console.print("[bold]Restarting step-ca service...[/bold]")
    _ssh_run(ip, "systemctl restart step-ca")

    # 9. Verify it's running
    check = _ssh_run(ip, "sleep 2 && systemctl is-active step-ca", check=False)
    if "active" in (check.stdout or ""):
        console.print("[green]step-ca is running![/green]")
    else:
        status = _ssh_run(ip, "journalctl -u step-ca -n 10 --no-pager", check=False)
        console.print(f"[yellow]WARNING:[/yellow] step-ca may not have started cleanly:")
        console.print(f"[dim]{status.stdout.strip()}[/dim]")

    # 10. Show root CA fingerprint for trust configuration
    fp = _ssh_run(ip, f"step certificate fingerprint {data_dir}/certs/root_ca.crt 2>/dev/null", check=False)
    if fp.stdout.strip():
        console.print(f"\n[bold]Root CA fingerprint:[/bold] {fp.stdout.strip()}")
        console.print(f"[dim]Other services can trust this CA with:[/dim]")
        from .config import internal_domain
        console.print(f"  step ca bootstrap --ca-url https://ca.{internal_domain()}:9000 --fingerprint {fp.stdout.strip()}")
