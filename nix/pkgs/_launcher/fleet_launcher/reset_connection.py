"""fleet reset-connection — Kill stale SSH/nix-copy processes to fleet hosts.

Symptoms this addresses:
    - `sk deploy nixos apply` hangs indefinitely at "copying path ..."
    - Multiple orphaned `nix ... copy` processes show up in `ps`
    - Nix daemon on target seems stuck after a previous killed deploy

Typical cause: a previous deploy was interrupted (SIGKILL, TTY loss, etc.)
and the local `nix copy` subprocess + ssh tunnels survived, now holding
file locks or daemon connections on the target. A fresh deploy then
contends with the zombies and appears to hang.

Usage examples:
    sk devtools reset-connection                   # reset ALL fleet hosts
    sk devtools reset-connection observe           # one host by name
    sk devtools reset-connection 192.0.2.104       # by IP
    sk devtools reset-connection 104               # by VMID
    sk devtools reset-connection observe --restart-daemon --gc
    sk devtools reset-connection --dry-run
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys

import click
from rich.console import Console
from rich.table import Table

from ._util import find_project_root, fleet_cache_dir

console = Console()


# ── Host resolution ──────────────────────────────────────────────

def _load_hosts() -> dict[str, dict]:
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found — run `fleet inventory generate` first")
        sys.exit(1)
    with open(hosts_file) as f:
        return json.load(f)


def _ips_for(host_meta: dict) -> list[str]:
    """Return the deduped list of IPs for a host entry (vmbr0 + vmbr1)."""
    seen = set()
    out = []
    for ip in (host_meta.get("ip"), host_meta.get("internal_ip")):
        if ip and ip not in seen:
            seen.add(ip)
            out.append(ip)
    return out


def _resolve_targets(target: str | None, hosts: dict) -> dict[str, list[str]]:
    """Return { host_name: [ips...] }.

    TARGET can be:
        - None              → all fleet hosts
        - host name         → exact or fuzzy match (e.g. "observe", "btc-main")
        - VMID (int string) → match by hosts.json vmid
        - IP (x.y.z.w)      → any host with that IP (or the bare IP if no match)
    """
    if target is None:
        return {name: ips for name, meta in hosts.items() if (ips := _ips_for(meta))}

    # VMID
    if target.isdigit():
        vmid = int(target)
        for name, meta in hosts.items():
            if meta.get("vmid") == vmid:
                return {name: _ips_for(meta)}
        console.print(f"[red]No host with VMID {vmid} in hosts.json[/red]")
        sys.exit(1)

    # IP address
    if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", target):
        for name, meta in hosts.items():
            if target in _ips_for(meta):
                return {name: [target]}
        # Unknown IP — still allow, caller may want to clean up to an ad-hoc target
        console.print(f"[yellow]IP {target} is not in hosts.json — cleaning up anyway[/yellow]")
        return {f"<ip>{target}": [target]}

    # Name — exact match first
    if target in hosts:
        return {target: _ips_for(hosts[target])}

    # Fuzzy name match
    matches = [name for name in hosts if target in name]
    if len(matches) == 1:
        return {matches[0]: _ips_for(hosts[matches[0]])}
    if matches:
        console.print(f"[yellow]Ambiguous match:[/yellow] {', '.join(matches)}")
        sys.exit(1)

    console.print(f"[red]No host/VMID/IP match for '{target}'[/red]")
    console.print(f"Available: {', '.join(sorted(hosts))}")
    sys.exit(1)


# ── Process discovery + kill ─────────────────────────────────────

# Patterns that identify orphaned nix deploy processes targeting a given IP.
# The {ip} placeholder is substituted per-target. Matched against the `cmd`
# column of `ps axo`.
_PROCESS_PATTERNS = [
    r"nix.*copy.*{ip}",            # nix --... copy --to ssh-ng://root@ip
    r"ssh.*{ip}.*nix-daemon",      # ssh root@ip ... nix-daemon --stdio
    r"ssh -W \[{ip}\]:22",         # ProxyJump tunnel for host ip
]

# Broader patterns (matched regardless of target IP) for `--broad` mode.
# These catch orphan deploy-related processes that don't have a specific IP
# visible in their cmdline — e.g. bare `colmena`, generic `nix ... copy`,
# or `ssh ... nix-daemon --stdio` without an obvious destination.
_BROAD_PATTERNS = [
    r"\bcolmena\b",                      # any colmena process
    r"nix-copy-closure",                  # legacy command
    r"nix .*copy.*--to ssh-ng://",       # any nix copy via ssh-ng, any dest
    r"ssh .*nix-daemon --stdio",         # any ssh with nix-daemon stdio
]


def _ps_snapshot() -> list[tuple[int, str]]:
    """Return [(pid, cmd), ...] from the local process list."""
    try:
        ps_out = subprocess.check_output(
            ["ps", "-eo", "pid,cmd", "--no-headers"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        return []

    my_pid = os.getpid()
    snap: list[tuple[int, str]] = []
    for line in ps_out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(maxsplit=1)
        if len(parts) < 2:
            continue
        pid_str, cmd = parts
        try:
            pid = int(pid_str)
        except ValueError:
            continue
        if pid == my_pid:
            continue
        snap.append((pid, cmd))
    return snap


def _find_processes_for_ip(ip: str, snapshot: list[tuple[int, str]] | None = None) -> list[dict]:
    """Scan running processes for ones matching the per-IP orphan patterns."""
    ip_re = re.escape(ip)
    patterns = [p.format(ip=ip_re) for p in _PROCESS_PATTERNS]
    snap = snapshot if snapshot is not None else _ps_snapshot()
    results: list[dict] = []
    for pid, cmd in snap:
        for pat in patterns:
            if re.search(pat, cmd):
                results.append({"pid": pid, "cmd": cmd})
                break
    return results


def _find_broad_processes(snapshot: list[tuple[int, str]] | None = None) -> list[dict]:
    """Scan for deploy-related processes regardless of target IP (broad mode)."""
    snap = snapshot if snapshot is not None else _ps_snapshot()
    results: list[dict] = []
    for pid, cmd in snap:
        for pat in _BROAD_PATTERNS:
            if re.search(pat, cmd):
                results.append({"pid": pid, "cmd": cmd})
                break
    return results


def _kill(pid: int) -> tuple[bool, str]:
    """SIGKILL a pid. Returns (success, message)."""
    try:
        os.kill(pid, signal.SIGKILL)
        return True, "killed"
    except ProcessLookupError:
        return False, "already gone"
    except PermissionError:
        return False, "permission denied"


# ── Remote actions (restart nix-daemon, garbage-collect) ─────────

def _ssh_run(ip: str, cmd: str, *, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    """Run a shell command on a target host via SSH. Returns CompletedProcess."""
    return subprocess.run(
        [
            "ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            f"root@{ip}",
            cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _remote_restart_daemon(host_name: str, ip: str) -> None:
    """Full nix-daemon reset: stop, kill stdio zombies, checkpoint WAL, restart.

    A plain `systemctl restart nix-daemon` is insufficient after a hung deploy
    because SSH-spawned `nix-daemon --stdio` sessions are not part of the
    service unit and survive the restart. These zombies hold SQLite WAL
    locks open, preventing checkpoint. Symptoms: DB main file stale while
    the WAL balloons, and incoming `nix copy` queries hang forever even
    though the target already has the path.
    """
    console.print(f"  [cyan]→[/cyan] {host_name} ({ip}): full nix-daemon reset")

    # One-shot script: stop, kill zombies, checkpoint WAL, start.
    # `nix-shell -p sqlite` is used because sqlite3 is not in the base PATH
    # on typical NixOS containers; if it can't be fetched (no network/cache),
    # we skip the checkpoint — the restart alone will still help.
    script = (
        "set +e; "
        "systemctl stop nix-daemon nix-daemon.socket 2>/dev/null; "
        'pkill -9 -f "nix-daemon --stdio" 2>/dev/null; '
        'pkill -9 -f "^nix-daemon [0-9]" 2>/dev/null; '
        "sleep 1; "
        "(command -v sqlite3 || nix-shell -p sqlite --run true) >/dev/null 2>&1 "
        '  && sqlite_bin=$(command -v sqlite3 || nix-shell -p sqlite --run "command -v sqlite3") '
        '  && $sqlite_bin /nix/var/nix/db/db.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null '
        "  && echo 'WAL checkpointed'; "
        "systemctl start nix-daemon; "
        "sleep 2; "
        "systemctl is-active nix-daemon; "
        "wal=$(stat -c%s /nix/var/nix/db/db.sqlite-wal 2>/dev/null || echo 0); "
        "echo \"WAL: ${wal} bytes\""
    )
    try:
        result = _ssh_run(ip, script, timeout=120)
    except subprocess.TimeoutExpired:
        console.print(f"    [red]TIMEOUT[/red] resetting nix-daemon on {ip}")
        return

    for line in (result.stdout + result.stderr).strip().splitlines():
        if line.strip():
            tag = "[green]✓[/green]" if "active" in line.lower() or "checkpoint" in line.lower() else "[dim]·[/dim]"
            console.print(f"    {tag} {line}")
    if result.returncode != 0:
        console.print(f"    [red]exit {result.returncode}[/red]")


def _remote_gc(host_name: str, ip: str) -> None:
    console.print(f"  [cyan]→[/cyan] {host_name} ({ip}): nix-collect-garbage -d")
    try:
        result = _ssh_run(ip, "nix-collect-garbage -d 2>&1 | tail -3", timeout=300)
    except subprocess.TimeoutExpired:
        console.print(f"    [red]TIMEOUT[/red] gc on {ip} (>5min)")
        return
    if result.returncode == 0:
        for line in (result.stdout + result.stderr).strip().splitlines():
            console.print(f"    [dim]{line}[/dim]")
    else:
        console.print(f"    [red]failed[/red]: {result.stderr.strip()}")


# ── CLI command ──────────────────────────────────────────────────

@click.command("reset-connection")
@click.argument("target", required=False)
@click.option("--restart-daemon", is_flag=True,
              help="After killing local orphans, SSH to each target and restart nix-daemon.")
@click.option("--gc", is_flag=True,
              help="After killing local orphans, SSH to each target and nix-collect-garbage -d.")
@click.option("--broad", is_flag=True,
              help="Also kill deploy-related processes regardless of target IP "
                   "(colmena, bare nix-copy, any ssh nix-daemon --stdio). "
                   "Use when something is stuck but doesn't show the IP in its cmdline.")
@click.option("--dry-run", is_flag=True,
              help="Show what would be killed without actually killing.")
def reset_connection(target: str | None, restart_daemon: bool, gc: bool,
                     broad: bool, dry_run: bool) -> None:
    """Kill stale SSH and nix-copy processes to fleet hosts.

    \b
    Use when `sk deploy nixos apply` hangs indefinitely on "copying path...".
    Root cause is usually orphaned nix/ssh subprocesses from a previously
    killed deploy holding locks on the target's nix-daemon.

    \b
    TARGET can be:
        - omitted  → reset connections to ALL fleet hosts
        - name     → observe, devops, btc-mainnet (fuzzy-matched)
        - VMID     → 104, 205, etc.
        - IP       → 192.0.2.104

    \b
    Examples:
        sk devtools reset-connection
        sk devtools reset-connection observe
        sk devtools reset-connection 192.0.2.104 --restart-daemon --gc
        sk devtools reset-connection --dry-run
    """
    hosts = _load_hosts()
    targets = _resolve_targets(target, hosts)

    if not targets:
        console.print("[yellow]No targets to reset.[/yellow]")
        return

    if dry_run:
        console.print("[bold yellow]DRY RUN[/bold yellow] — no processes will be killed")

    # Snapshot ps once so per-IP and broad scans work off the same view.
    snapshot = _ps_snapshot()

    # ── Scan + kill orphaned processes (per-IP) ──
    table = Table(title="Orphaned processes per host (IP-scoped)",
                  show_header=True, header_style="bold cyan")
    table.add_column("Host", style="green")
    table.add_column("IPs", style="dim")
    table.add_column("PIDs found", justify="right")
    table.add_column("Killed", justify="right")
    table.add_column("Details", style="dim")

    total_killed = 0
    killed_globally: set[int] = set()
    # In dry-run we also want to dedup the broad table against PIDs we already
    # planned to kill from the per-IP scan, so track those too.
    planned_kill_pids: set[int] = set()
    for host_name, ips in sorted(targets.items()):
        all_procs: list[dict] = []
        for ip in ips:
            all_procs.extend(_find_processes_for_ip(ip, snapshot))

        # dedup by pid (a process may match against both vmbr0 and vmbr1 IPs)
        seen = set()
        procs = []
        for p in all_procs:
            if p["pid"] not in seen:
                seen.add(p["pid"])
                procs.append(p)

        killed_pids = []
        detail_lines = []
        for p in procs:
            pid = p["pid"]
            planned_kill_pids.add(pid)
            if dry_run:
                detail_lines.append(f"would kill PID {pid}")
                continue
            ok, msg = _kill(pid)
            if ok:
                killed_pids.append(pid)
                killed_globally.add(pid)
            detail_lines.append(f"PID {pid}: {msg}")

        total_killed += len(killed_pids)
        table.add_row(
            host_name,
            ", ".join(ips),
            str(len(procs)) if procs else "[dim]0[/dim]",
            str(len(killed_pids)) if killed_pids else "[dim]0[/dim]",
            "\n".join(detail_lines) or "[dim](clean)[/dim]",
        )

    console.print(table)

    # ── Broad scan (no IP required) ──
    if broad:
        # Exclude PIDs already handled (killed in live mode, planned in dry-run)
        exclude = killed_globally if not dry_run else planned_kill_pids
        broad_procs = [p for p in _find_broad_processes(snapshot)
                       if p["pid"] not in exclude]
        broad_table = Table(title="Broad scan (global deploy-related processes)",
                            show_header=True, header_style="bold magenta")
        broad_table.add_column("PID", justify="right")
        broad_table.add_column("Status")
        broad_table.add_column("Command", style="dim", overflow="fold")

        broad_killed = 0
        for p in broad_procs:
            pid = p["pid"]
            cmd_preview = p["cmd"][:120] + ("…" if len(p["cmd"]) > 120 else "")
            if dry_run:
                broad_table.add_row(str(pid), "[yellow]would kill[/yellow]", cmd_preview)
                continue
            ok, msg = _kill(pid)
            if ok:
                broad_killed += 1
                killed_globally.add(pid)
            broad_table.add_row(str(pid), "[green]killed[/green]" if ok else f"[red]{msg}[/red]",
                                cmd_preview)

        if broad_procs:
            console.print(broad_table)
            total_killed += broad_killed
        else:
            console.print("[dim](broad scan found no additional processes)[/dim]")

    if dry_run:
        console.print(f"\n[yellow]DRY RUN[/yellow]: would have killed processes across {len(targets)} host(s).")
        return

    console.print(f"\n[green]Killed {total_killed}[/green] orphaned process(es) across {len(targets)} host(s).")

    # ── Optional remote actions ──
    if restart_daemon or gc:
        console.print()
        console.print("[bold]Remote actions:[/bold]")
        for host_name, ips in sorted(targets.items()):
            if host_name.startswith("<ip>"):
                # Ad-hoc IP target — still allow remote ops
                ip = ips[0]
            else:
                # Prefer internal_ip for remote ops (what hosts.json says is canonical)
                ip = hosts.get(host_name, {}).get("internal_ip") or hosts.get(host_name, {}).get("ip") or ips[0]

            if restart_daemon:
                _remote_restart_daemon(host_name, ip)
            if gc:
                _remote_gc(host_name, ip)

    console.print("\n[bold]Next step:[/bold] retry your deploy:")
    console.print("  [cyan]nix develop -c colmena apply --impure --on <host> --verbose[/cyan]")
