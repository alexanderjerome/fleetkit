"""fleet pbs — Proxmox Backup Server operator helpers.

Mirrors the `sk pve cluster issue-tf-token` flow for the PBS host: mints
an API token via `proxmox-backup-manager`, saves to SOPS, and pairs with
the fleet.providers.proxmox-backup-server.<instance> declaration in
nix/fleet/providers/inputs.nix.

PBS has no cluster concept (single-host product), so this lives at
`sk pbs ...` rather than `sk pbs cluster ...`.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir
from .pve_api import get_host as get_pve_host

console = Console()


def _load_hosts() -> dict:
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    if not hosts_file.exists():
        console.print(
            "[red]ERROR:[/red] .cache/fleet/hosts.json not found — run "
            "`fleet inventory generate` first"
        )
        sys.exit(1)
    with open(hosts_file) as f:
        return json.load(f)


def _pbs_host(hosts: dict) -> tuple[str, dict]:
    """Find the PBS host (tag = pbs-host) in fleet.compute."""
    matches = [(n, m) for n, m in hosts.items()
               if "pbs-host" in m.get("tags", [])]
    if not matches:
        console.print(
            "[red]ERROR:[/red] no host carries the 'pbs-host' tag in fleet.compute"
        )
        sys.exit(1)
    if len(matches) > 1:
        names = ", ".join(n for n, _ in matches)
        console.print(f"[red]ERROR:[/red] multiple pbs-host tagged: {names}")
        sys.exit(1)
    return matches[0]


def _ssh(ip: str, cmd: str, *, timeout: int = 30) -> subprocess.CompletedProcess:
    ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={timeout}",
        "-o", "BatchMode=yes",
        f"root@{ip}",
        cmd,
    ]
    return subprocess.run(ssh_cmd, capture_output=True, text=True, check=False)


def _cluster_members(pve_ip: str) -> dict[str, str]:
    """Map PVE node name -> node IP from /etc/pve/.members (read on any node)."""
    res = _ssh(pve_ip, "cat /etc/pve/.members")
    if res.returncode != 0:
        console.print(f"[red]ERROR:[/red] could not read cluster members via {pve_ip}: "
                      f"{res.stderr.strip()}")
        sys.exit(1)
    data = json.loads(res.stdout)
    return {name: info.get("ip") for name, info in data.get("nodelist", {}).items()}


def _owner_node(pve_ip: str, vmid: int) -> str | None:
    """Return the cluster node name that currently owns CT/VM `vmid`."""
    res = _ssh(pve_ip, "pvesh get /cluster/resources --type vm --output-format json")
    if res.returncode != 0:
        return None
    for r in json.loads(res.stdout):
        if r.get("vmid") == vmid:
            return r.get("node")
    return None


@click.group("pbs")
def pbs() -> None:
    """Proxmox Backup Server operator commands."""


@pbs.command("issue-tf-token")
@click.option("--user", "username", default="terranix@pbs", show_default=True,
              help="PBS user to create / use. Use @pbs (built-in PBS realm).")
@click.option("--token-id", "token_id", default="terranix", show_default=True,
              help="API token ID to mint.")
@click.option("--sops-prefix", default=None, show_default="integrations/pbs/<fleet>-pbs",
              help="SOPS path prefix for endpoint + api_token.")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation.")
def issue_tf_token(username: str, token_id: str, sops_prefix: str, yes: bool) -> None:
    """Mint a PBS API token for terranix on the pbs host.

    Idempotent steps on pbs (root via SSH, proxmox-backup-manager CLI):
      1. Create `<username>` if absent. PBS users in the @pbs realm are
         self-contained (no Linux/PAM dependency).
      2. Grant Admin on / via `proxmox-backup-manager acl update`.
      3. Remove any existing `<token_id>` token, then generate a fresh
         one and capture the UUID.
      4. Save to SOPS:
           <sops-prefix>/endpoint   = https://<pbs-ip>:8007
           <sops-prefix>/api_token  = <username>!<token-id>=<value>
         The api_token format matches what
         Tinyblargon/proxmox-backup-server's `api_token` attribute
         expects.

    The provider config in nix/fleet/providers/inputs.nix references
    these via `secrets.api_token = "<sops-prefix>/api_token"`.
    """
    if sops_prefix is None:
        from .config import fleet_name
        sops_prefix = f"integrations/pbs/{fleet_name()}-pbs"
    hosts = _load_hosts()
    name, meta = _pbs_host(hosts)
    ip = meta["internal_ip"]
    endpoint = f"https://{ip}:8007"

    console.print(f"[bold]Host:[/bold]  {name} ({endpoint})")
    console.print(f"[bold]User:[/bold]  {username}")
    console.print(f"[bold]Token:[/bold] {token_id}")
    console.print(f"[bold]SOPS:[/bold]  {sops_prefix}/{{endpoint,api_token}}")
    console.print()

    if not yes and not click.confirm("Mint token + save to SOPS?", default=False):
        console.print("aborted")
        sys.exit(1)

    # The PBS user check uses --output-format json and a tiny python
    # one-liner — same idiom as the PVE counterpart.
    remote = f"""
set -euo pipefail

# 1. user (idempotent)
if ! proxmox-backup-manager user list --output-format json 2>/dev/null | python3 -c "import json,sys; sys.exit(0 if any(u.get('userid')=='{username}' for u in json.load(sys.stdin)) else 1)" 2>/dev/null; then
  pw=$(openssl rand -base64 32)
  proxmox-backup-manager user create {username} --password "$pw" --comment 'Terranix automation user'
fi

# 2. ACL: Admin on /
proxmox-backup-manager acl update / Admin --auth-id {username}

# 3. token: remove if exists (silent if not), then generate fresh.
# `generate-token` doesn't accept --output-format on this PBS version
# — it always prints "Result: { ... }" with a pretty-printed JSON
# block. Parser strips the "Result:" prefix.
proxmox-backup-manager user delete-token {username} {token_id} 2>/dev/null || true
proxmox-backup-manager user generate-token {username} {token_id}
"""

    console.print(f"  running on {name}...", style="dim")
    res = _ssh(ip, remote, timeout=30)
    if res.returncode != 0:
        console.print(f"[red]FAILED on {name}[/] (exit {res.returncode})")
        if res.stderr:
            console.print(f"  stderr: {res.stderr.strip()}")
        sys.exit(res.returncode)

    # PBS's `user generate-token` prints "Result: {\n  ...\n}" — a
    # pretty-printed JSON block prefixed by "Result: ". Find the first
    # "{" anywhere in stdout and decode from there with raw_decode so
    # any trailing whitespace is tolerated.
    out = res.stdout
    brace = out.find("{")
    if brace < 0:
        console.print(f"[red]Could not find JSON in pbs output[/]:\n{out}")
        sys.exit(1)
    try:
        payload, _ = json.JSONDecoder().raw_decode(out[brace:])
    except json.JSONDecodeError as e:
        console.print(f"[red]Failed to parse pbs token JSON[/]: {e}\noutput: {out}")
        sys.exit(1)

    # PBS token payload shape:
    #   {"tokenid": "terranix@pbs!terranix", "value": "<UUID>"}
    secret_value = payload.get("value")
    token_full = payload.get("tokenid")
    if not secret_value or not token_full:
        console.print(f"[red]Missing value/tokenid in payload[/]: {payload}")
        sys.exit(1)

    api_token = f"{token_full}={secret_value}"
    console.print(f"  ✓ minted token [cyan]{token_full}[/]")

    for path, value in [(f"{sops_prefix}/endpoint", endpoint),
                        (f"{sops_prefix}/api_token", api_token)]:
        sk_res = subprocess.run(
            ["sk", "devtools", "secrets", "keys", "add", path, value],
            capture_output=True, text=True, check=False,
        )
        if sk_res.returncode != 0:
            console.print(f"[red]Failed to save {path}[/]: {sk_res.stderr.strip()}")
            sys.exit(sk_res.returncode)
        console.print(f"  ✓ wrote SOPS: [cyan]{path}[/]")

    console.print()
    console.print("[green]Token minted + saved to SOPS.[/]")


@pbs.command("backup")
@click.argument("host_name")
@click.option("--storage", default="pbs-garage", show_default=True,
              help="PVE storage target (a PBS datastore).")
@click.option("--mode", default="snapshot",
              type=click.Choice(["snapshot", "suspend", "stop"]), show_default=True,
              help="vzdump mode. snapshot = no downtime (LVM-thin snapshot).")
@click.option("--exclude-path", "exclude_paths", multiple=True,
              help="Path to exclude from the backup (repeatable), e.g. /data/nbxplorer.")
@click.option("--notes", default="{{guestname}} — sk pbs backup", show_default=True,
              help="vzdump notes-template for the snapshot.")
@click.option("--pve-host", "pve_host_override", default=None,
              help="Cluster node IP to query (default: PROXMOX_VE_ENDPOINT).")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation.")
def backup(host_name: str, storage: str, mode: str, exclude_paths: tuple[str, ...],
           notes: str, pve_host_override: str | None, yes: bool) -> None:
    """Back up a fleet container/VM to PBS via vzdump.

    Resolves HOST_NAME -> vmid from hosts.json, finds the cluster node that
    currently owns the guest, runs `vzdump` there targeting the PBS storage,
    and confirms the snapshot landed.

    \b
    Examples:
        sk pbs backup indexer-mainnet
        sk pbs backup indexer-mainnet --exclude-path /data/nbxplorer
        sk pbs backup btc-mainnet --mode snapshot -y
    """
    hosts = _load_hosts()
    if host_name not in hosts:
        matches = [h for h in hosts if host_name in h]
        if len(matches) == 1:
            host_name = matches[0]
        elif matches:
            console.print(f"[yellow]Ambiguous match:[/yellow] {', '.join(matches)}")
            sys.exit(1)
        else:
            console.print(f"[red]Host '{host_name}' not found.[/red] "
                          f"Available: {', '.join(sorted(hosts))}")
            sys.exit(1)

    host = hosts[host_name]
    vmid = host.get("vmid")
    if not vmid:
        console.print(f"[red]ERROR:[/red] '{host_name}' has no vmid (not a PVE guest).")
        sys.exit(1)

    pve = pve_host_override or get_pve_host()
    if not pve:
        console.print("[red]ERROR:[/red] no cluster endpoint — set PROXMOX_VE_ENDPOINT "
                      "(source .env) or pass --pve-host <ip>.")
        sys.exit(1)

    members = _cluster_members(pve)
    node = _owner_node(pve, int(vmid))
    if not node or node not in members:
        console.print(f"[red]ERROR:[/red] could not locate the node owning CT {vmid} "
                      f"(found node={node!r}).")
        sys.exit(1)
    node_ip = members[node]

    console.print(f"[bold]Backup[/bold] {host_name} (CT {vmid}) on [cyan]{node}[/] "
                  f"({node_ip}) → [cyan]{storage}[/], mode={mode}")
    if exclude_paths:
        console.print(f"  excluding: {', '.join(exclude_paths)}")
    if not yes and not click.confirm("Proceed?"):
        console.print("aborted")
        return

    excl = "".join(f" --exclude-path {p}" for p in exclude_paths)
    unit = f"sk-backup-{vmid}"
    logfile = f"/var/log/{unit}.log"
    vzcmd = (f"vzdump {vmid} --storage {storage} --mode {mode} "
             f"--notes-template '{notes}'{excl}")

    # Run vzdump DETACHED under a transient systemd unit so a long backup
    # survives operator SSH drops (vzdump tethered to an ssh channel dies on
    # disconnect). Poll the log for completion instead of streaming.
    launch = (
        f"systemctl reset-failed {unit} 2>/dev/null; "
        f"systemd-run --unit={unit} --service-type=oneshot bash -c "
        f"'{vzcmd} > {logfile} 2>&1; echo SK_BACKUP_EXIT=$? >> {logfile}'"
    )
    console.print(f"[dim]{node_ip}: launching {unit} (detached)[/dim]")
    r = _ssh(node_ip, launch)
    if r.returncode != 0:
        console.print(f"[red]Failed to launch backup unit:[/] {r.stderr.strip()}")
        sys.exit(1)

    console.print("[dim]polling (backup runs server-side; safe to Ctrl-C the poll)…[/dim]")
    last = ""
    exit_code = None
    while exit_code is None:
        res = _ssh(node_ip,
                   f"grep -q SK_BACKUP_EXIT {logfile} && tail -4 {logfile} || tail -1 {logfile}")
        out = (res.stdout or "").strip()
        line = out.splitlines()[-1] if out else ""
        if line and line != last:
            console.print(f"  {line}")
            last = line
        m = re.search(r"SK_BACKUP_EXIT=(\d+)", out)
        if m:
            exit_code = int(m.group(1))
            break
        time.sleep(30)

    if exit_code != 0:
        console.print(f"[red]vzdump failed (exit {exit_code}).[/] See {node_ip}:{logfile}")
        sys.exit(exit_code)

    res = _ssh(pve, f"pvesm list {storage} --vmid {vmid}")
    console.print(f"[green]✓ Backup complete + on PBS.[/] Snapshots for CT {vmid} on {storage}:")
    console.print((res.stdout or res.stderr).strip())
