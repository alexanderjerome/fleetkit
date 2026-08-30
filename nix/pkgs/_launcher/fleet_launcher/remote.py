"""Remote command execution on fleet hosts.

Provides `sk remote <host> <command>` for quick SSH access to any container
in the fleet, resolving the IP from hosts.json. With --pct-exec, routes
through the Proxmox host using `pct exec` (useful when SSH is broken on
the target container).
"""
from __future__ import annotations

import json
import subprocess
import sys

import click
from rich.console import Console

from ._util import find_project_root
from .pve_api import get_host as get_pve_host
from .pve_ssh import ensure_master, run_on_host

console = Console()


def _load_hosts() -> dict:
    root = find_project_root()
    hosts_file = root / ".cache" / "sk" / "hosts.json"
    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/sk/hosts.json not found — run `sk inventory generate` first")
        sys.exit(1)
    with open(hosts_file) as f:
        return json.load(f)


@click.command("remote")
@click.argument("host_name")
@click.argument("command", nargs=-1, required=True)
@click.option("--pct-exec", "use_pct", is_flag=True,
              help="Route through Proxmox host via pct exec (bypasses container SSH)")
@click.option("--user", default="root", help="SSH user (default: root)")
def remote(host_name: str, command: tuple[str, ...], use_pct: bool, user: str) -> None:
    """Run a command on a fleet host.

    Resolves HOST_NAME from hosts.json and SSHs directly. Use --pct-exec
    when the container's SSH is unreachable (disk full, broken sshd, etc.)
    to route through the Proxmox host instead.

    \b
    Examples:
        sk remote grafana "systemctl status grafana"
        sk remote btc-mainnet "df -h"
        sk remote btc-mainnet --pct-exec "journalctl -u mempool --no-pager -n 20"
    """
    hosts = _load_hosts()

    if host_name not in hosts:
        # Try fuzzy match
        matches = [h for h in hosts if host_name in h]
        if len(matches) == 1:
            host_name = matches[0]
        elif matches:
            console.print(f"[yellow]Ambiguous match:[/yellow] {', '.join(matches)}")
            return
        else:
            console.print(f"[red]Host '{host_name}' not found.[/red] Available: {', '.join(sorted(hosts))}")
            return

    host = hosts[host_name]
    # Fleet-declared hosts.json leaves ip="" for single-internal containers
    # (no vmbr0 leg) — the internal service IP is the reachable one.
    ip = host["ip"] or host.get("internal_ip", "")
    vmid = host["vmid"]
    cmd_str = " ".join(command)

    if use_pct:
        pve_host = get_pve_host()
        if not pve_host:
            console.print("[red]ERROR:[/red] PROXMOX_VE_ENDPOINT not set — can't route via PVE host")
            return

        console.print(f"[dim]pct exec {vmid} on {pve_host} ({host_name}):[/dim] {cmd_str}")
        ensure_master(pve_host, user)
        result = run_on_host(
            pve_host,
            f"pct exec {vmid} -- /bin/sh -c '{cmd_str.replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))}'",
            user=user, timeout=120,
        )
    else:
        if not ip:
            console.print(f"[red]ERROR:[/red] no ip/internal_ip for '{host_name}' in hosts.json — try --pct-exec")
            sys.exit(1)
        console.print(f"[dim]ssh {user}@{ip} ({host_name}):[/dim] {cmd_str}")
        result = subprocess.run(
            ["ssh",
             "-o", "StrictHostKeyChecking=accept-new",
             "-o", "ConnectTimeout=10",
             f"{user}@{ip}",
             cmd_str],
            capture_output=False,
            timeout=120,
        )

    if use_pct:
        if result.stdout:
            click.echo(result.stdout, nl=False)
        if result.stderr:
            click.echo(result.stderr, nl=False, err=True)

    sys.exit(result.returncode)
