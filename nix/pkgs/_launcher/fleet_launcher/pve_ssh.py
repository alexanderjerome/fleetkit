"""Managed SSH connection to the Proxmox VE host.

Uses SSH ControlMaster for persistent multiplexed connections. One master
connection stays alive and all subsequent SSH/pct commands reuse it,
avoiding the repeated connect/timeout issues with ephemeral connections.

For container operations (pct exec, pct push) there is no REST API
equivalent — these must go through SSH to the PVE host.
"""
from __future__ import annotations

import atexit
import os
import subprocess
import tempfile
import time
from pathlib import Path

from rich.console import Console

console = Console()

# ---------------------------------------------------------------------------
# ControlMaster connection pool
# ---------------------------------------------------------------------------

_SOCKET_DIR = Path(tempfile.gettempdir()) / "fleet-ssh"
_SOCKET_PATH = _SOCKET_DIR / "pve-control-%C"
_master_started = False


def _ssh_base_args(host: str, user: str = "root") -> list[str]:
    """Base SSH args with ControlMaster settings."""
    _SOCKET_DIR.mkdir(mode=0o700, exist_ok=True)
    return [
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", f"ControlPath={_SOCKET_PATH}",
        "-o", "ControlPersist=300",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=30",
        f"{user}@{host}",
    ]


def ensure_master(host: str, user: str = "root",
                   retries: int = 3, retry_delay: float = 10.0) -> bool:
    """Start the ControlMaster if not already running.

    Retries up to `retries` times with exponential backoff.
    Returns True if the master connection is alive.
    """
    global _master_started

    # Check if master is already running.
    check = subprocess.run(
        ["ssh", "-O", "check",
         "-o", f"ControlPath={_SOCKET_PATH}",
         f"{user}@{host}"],
        capture_output=True, text=True,
    )
    if check.returncode == 0:
        _master_started = True
        return True

    _SOCKET_DIR.mkdir(mode=0o700, exist_ok=True)

    for attempt in range(1, retries + 1):
        console.print(f"[dim]Opening SSH master to {host} (attempt {attempt}/{retries})...[/dim]")

        result = subprocess.run(
            ["ssh",
             "-o", "StrictHostKeyChecking=accept-new",
             "-o", f"ControlPath={_SOCKET_PATH}",
             "-o", "ControlMaster=yes",
             "-o", "ControlPersist=300",
             "-o", "ServerAliveInterval=15",
             "-o", "ServerAliveCountMax=3",
             "-o", "ConnectTimeout=30",
             "-o", "BatchMode=yes",
             "-fN",  # Background, no command
             f"{user}@{host}"],
            capture_output=True, text=True,
            timeout=45,
        )

        if result.returncode == 0:
            _master_started = True
            atexit.register(lambda: close_master(host, user))
            console.print(f"[dim]SSH master connected to {host}[/dim]")
            return True

        if attempt < retries:
            delay = retry_delay * attempt
            console.print(f"[yellow]SSH attempt {attempt} failed, retrying in {delay:.0f}s...[/yellow]")
            time.sleep(delay)

    console.print(f"[red]SSH master failed after {retries} attempts:[/red] {result.stderr.strip()}")
    return False


def close_master(host: str, user: str = "root") -> None:
    """Close the ControlMaster connection."""
    subprocess.run(
        ["ssh", "-O", "exit",
         "-o", f"ControlPath={_SOCKET_PATH}",
         f"{user}@{host}"],
        capture_output=True,
    )


def run_on_host(host: str, command: str, user: str = "root",
                timeout: int = 60) -> subprocess.CompletedProcess:
    """Run a command on the PVE host via the managed SSH connection."""
    ensure_master(host, user)
    return subprocess.run(
        _ssh_base_args(host, user) + [command],
        capture_output=True, text=True, timeout=timeout,
    )


# ---------------------------------------------------------------------------
# pct operations (require SSH to PVE host)
# ---------------------------------------------------------------------------

def pct_exec(host: str, vmid: int, command: str,
             user: str = "root", timeout: int = 120) -> subprocess.CompletedProcess:
    """Run a command inside a container via pct exec."""
    return run_on_host(
        host, f"pct exec {vmid} -- /bin/sh -c {_shell_quote(command)}",
        user=user, timeout=timeout,
    )


def pct_push(host: str, vmid: int, local_path: str, container_path: str,
             user: str = "root") -> subprocess.CompletedProcess:
    """Push a file into a container.

    First SCPs to PVE host's /tmp, then uses pct push to inject into container.
    """
    ensure_master(host, user)
    tmp_name = f"/tmp/pct-push-{vmid}-{os.path.basename(local_path)}"

    # SCP to PVE host.
    scp_result = subprocess.run(
        ["scp",
         "-o", f"ControlPath={_SOCKET_PATH}",
         "-o", "BatchMode=yes",
         local_path, f"{user}@{host}:{tmp_name}"],
        capture_output=True, text=True, timeout=60,
    )
    if scp_result.returncode != 0:
        return scp_result

    # pct push from PVE host into container.
    push_result = run_on_host(
        host,
        f"pct push {vmid} {tmp_name} {container_path} && rm -f {tmp_name}",
        user=user,
    )
    return push_result


def pct_push_string(host: str, vmid: int, content: str, container_path: str,
                    user: str = "root") -> subprocess.CompletedProcess:
    """Push string content into a file inside a container."""
    ensure_master(host, user)
    # Write to temp file on PVE host, then pct push.
    escaped = content.replace("'", "'\\''")
    return run_on_host(
        host,
        f"TMPF=$(mktemp) && printf '%s' '{escaped}' > \"$TMPF\" "
        f"&& pct push {vmid} \"$TMPF\" {container_path} "
        f"&& rm -f \"$TMPF\"",
        user=user, timeout=30,
    )


def _shell_quote(s: str) -> str:
    """Shell-quote a string for safe embedding in ssh commands."""
    return "'" + s.replace("'", "'\\''") + "'"
