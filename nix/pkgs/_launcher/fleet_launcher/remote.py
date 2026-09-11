"""Remote command execution on fleet hosts.

Provides `fleet remote <host> <command>` for quick SSH access to any container
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

from ._util import find_project_root, fleet_cache_dir
from .pve_api import get_client, get_host as get_pve_host, node_address, resolve_node
from .pve_ssh import ensure_master, run_on_host

console = Console()


def _pct_host(vmid: int) -> str:
    """Address of the cluster member VMID actually runs on.

    `pct exec` only sees /etc/pve/nodes/<self>/lxc/<vmid>.conf, so it has to
    run on the guest's own node. PROXMOX_VE_ENDPOINT points at whichever
    member serves the API — in a cluster that is usually a different one, and
    using it fails with "Configuration file ... does not exist" against a
    perfectly healthy cluster. Fall back to the endpoint when the cluster
    lookup yields nothing: on a mono-host they are the same address anyway.
    """
    try:
        api = get_client()
        addr = node_address(api, resolve_node(api, vmid))
        if addr:
            return addr
    except Exception as exc:
        console.print(f"[yellow]WARN:[/yellow] cluster lookup failed ({exc}) — using the API endpoint")
    return get_pve_host()


def _load_hosts() -> dict:
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found — run `fleet inventory generate` first")
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
        fleet remote grafana "systemctl status grafana"
        fleet remote builder "df -h"
        fleet remote builder --pct-exec "journalctl -u nix-daemon --no-pager -n 20"
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
        pve_host = _pct_host(int(vmid))
        if not pve_host:
            console.print("[red]ERROR:[/red] PROXMOX_VE_ENDPOINT not set — can't route via PVE host")
            return

        console.print(f"[dim]pct exec {vmid} on {pve_host} ({host_name}):[/dim] {cmd_str}")
        ensure_master(pve_host, user)
        # pct exec attaches with a bare PATH — it does not read the guest's
        # login environment. On a NixOS guest that means even `systemctl` and
        # `df` are "command not found", which reads like a broken container
        # rather than a missing PATH. Prepend the system profile; on a
        # non-NixOS guest the directory simply is not there.
        inner = f"export PATH=/run/current-system/sw/bin:$PATH; {cmd_str}"
        result = run_on_host(
            pve_host,
            f"pct exec {vmid} -- /bin/sh -c '{inner.replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))}'",
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
