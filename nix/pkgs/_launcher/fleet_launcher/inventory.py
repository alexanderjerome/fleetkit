"""fleet inventory — Host inventory generation and network scanning."""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import click
from rich.console import Console
from rich.table import Table

from ._util import fleet_cache_dir
from ._util import find_project_root as _find_project_root

console = Console()


def _classifier_networks():
    """(lan_net, internal_net) used to classify agent-reported IPv4s.

    Read from the fleet catalog — network.lan_cidr / internal_cidr. Either
    may be None (key unset); classification then falls back to
    "first IP wins" for that bucket.
    """
    import ipaddress
    from .config import get
    nets = []
    for key in ("network.lan_cidr", "network.internal_cidr"):
        cidr = get(key)
        nets.append(ipaddress.ip_network(cidr, strict=False) if cidr else None)
    return tuple(nets)


def _ip_in(ip: str, net) -> bool:
    import ipaddress
    if net is None:
        return False
    try:
        return ipaddress.ip_address(ip) in net
    except ValueError:
        return False


def _query_pve_api(hosts_by_vmid: dict[int, str]) -> dict[int, dict]:
    """Query Proxmox REST API for container AND VM IPs and MACs.

    Args:
        hosts_by_vmid: mapping of vmid → pve_type ("lxc" or "vm")

    Returns per-interface data:
      - ip: primary routable IP (LAN-side, per [network].lan_cidr)
      - internal_ip: internal service IP (per [network].internal_cidr)
      - mac: primary MAC address
    """
    from .pve_api import (
        extract_ip_from_config,
        extract_mac_from_config,
        get_client,
        get_container_config,
        get_container_interfaces,
        list_containers,
    )

    try:
        api = get_client()
    except Exception as exc:
        console.print(f"[yellow]Warning:[/yellow] Cannot connect to PVE API: {exc}")
        return {}

    # Discover existing VMIDs (both LXC and VM)
    existing_vmids: set[int] = set()
    try:
        for ct in list_containers(api):
            existing_vmids.add(int(ct.get("vmid", 0)))
    except Exception:
        pass
    try:
        for vm in api.nodes("pve").qemu.get():
            existing_vmids.add(int(vm.get("vmid", 0)))
    except Exception:
        pass

    wanted = set(hosts_by_vmid.keys()) & existing_vmids
    result: dict[int, dict] = {}

    for vmid in sorted(wanted):
        pve_type = hosts_by_vmid[vmid]
        entry: dict = {"ip": "", "internal_ip": "", "mac": ""}

        if pve_type == "lxc":
            # LXC: use container-specific API
            for iface in get_container_interfaces(api, vmid):
                name = iface.get("name", "")
                if name in ("lo", ""):
                    continue
                inet = iface.get("inet", "")
                ip = inet.split("/")[0] if inet else ""
                if name == "eth0":
                    entry["ip"] = ip
                    entry["mac"] = iface.get("hwaddr", "")
                elif name == "eth1":
                    entry["internal_ip"] = ip

            # Fallback to config
            try:
                cfg = get_container_config(api, vmid)
                if not entry["mac"]:
                    entry["mac"] = extract_mac_from_config(cfg)
                if not entry["internal_ip"]:
                    entry["internal_ip"] = extract_ip_from_config(cfg)
                if not entry["ip"]:
                    entry["ip"] = entry["internal_ip"]
            except Exception:
                pass

        else:
            # VM: use QEMU agent for IPs, config for MAC
            try:
                agent_ifaces = api.nodes("pve").qemu(vmid).agent("network-get-interfaces").get().get("result", [])
                lan_net, internal_net = _classifier_networks()
                for iface in agent_ifaces:
                    name = iface.get("name", "")
                    if name in ("lo", ""):
                        continue
                    for addr in iface.get("ip-addresses", []):
                        if addr.get("ip-address-type") == "ipv4":
                            ip = addr["ip-address"]
                            if _ip_in(ip, lan_net):
                                entry["ip"] = ip
                            elif _ip_in(ip, internal_net):
                                entry["internal_ip"] = ip
                            elif not entry["ip"]:
                                entry["ip"] = ip
                    if not entry["mac"] and iface.get("hardware-address"):
                        mac = iface["hardware-address"]
                        if mac != "00:00:00:00:00:00":
                            entry["mac"] = mac
            except Exception:
                pass

            # Fallback to config for MAC and static IP
            try:
                cfg = api.nodes("pve").qemu(vmid).config.get()
                if not entry["mac"]:
                    entry["mac"] = extract_mac_from_config(cfg)
                if not entry["internal_ip"]:
                    entry["internal_ip"] = extract_ip_from_config(cfg)
                if not entry["ip"]:
                    entry["ip"] = entry["internal_ip"]
            except Exception:
                pass

        result[vmid] = entry

    return result


@click.group("inventory")
def inventory():
    """Host inventory generation and management.

    Builds and displays ``.cache/fleet/hosts.json`` — the single source of
    truth mapping container names to VMIDs, IPs, and metadata.
    """
    pass


def generate_hosts_json(*, offline: bool = False, quiet: bool = False) -> Path:
    """Materialise .cache/fleet/hosts.json from the Nix fleet module.

    The Nix fleet module is the single source
    of truth.  We shell out to ``nix build .#hostsJson`` and copy the
    resulting store path to ``.cache/fleet/hosts.json``.  No PVE API scrape —
    that path caused config drift (netgate's net0 static was being read
    back as internal_ip, which NixOS then re-applied).

    Called by the CLI command and by ``fleet deploy nixos`` so external
    Python consumers (remote.py, reset_connection.py, nixos.py tag
    aggregation) keep seeing a fresh on-disk copy.  The ``offline``
    kwarg is retained for signature compatibility but no longer has
    any effect.
    """
    _ = offline  # retained for backwards compatibility
    root = _find_project_root()

    if not quiet:
        console.print("Building [cyan]fleet.hostsJson[/cyan] via nix…")

    try:
        result = subprocess.run(
            ["nix", "build", ".#hostsJson", "--no-link", "--print-out-paths"],
            cwd=root, capture_output=True, text=True, check=True, timeout=120,
        )
    except subprocess.CalledProcessError as exc:
        console.print(f"[red]nix build .#hostsJson failed:[/red]\n{exc.stderr}")
        raise
    except subprocess.TimeoutExpired:
        console.print("[red]nix build .#hostsJson timed out after 120s[/red]")
        raise

    store_path = Path(result.stdout.strip())
    hosts = json.loads(store_path.read_text())

    # XCP-ng/XOA VMs DHCP their NICs — fleet.nix declares ip/internal_ip
    # as "" for them. Patch live values in by querying the XOA REST API.
    # No-op when XOA is unreachable or no entries are XOA-managed.
    try:
        from .xoa_api import discover_xo_ips
        # Resolve fleet.network UUIDs from the existing hosts.json data if
        # already present; otherwise we'll pick the first available IPv4
        # without WAN/internal discrimination, which is fine for the
        # initial sandbox case (single-NIC).
        hosts = discover_xo_ips(hosts)
    except Exception as exc:
        console.print(f"[yellow]Warning:[/yellow] XOA discovery skipped: {exc}")

    output = json.dumps(hosts, indent=2, sort_keys=True) + "\n"
    hosts_file = fleet_cache_dir(root) / "hosts.json"
    hosts_file.write_text(output)
    if not quiet:
        # pve_type is namespaced ("pve.lxc" / "pve.vm") since the fleet
        # manifest became the source; match the suffix.
        lxc = sum(1 for h in hosts.values() if str(h.get("pve_type", "")).endswith(".lxc"))
        vm = sum(1 for h in hosts.values() if str(h.get("pve_type", "")).endswith(".vm"))
        xoa = sum(
            1 for h in hosts.values()
            if str(h.get("provider_instance", "")).startswith("xen-orchestra.")
        )
        console.print(
            f"[green]Wrote[/green] {hosts_file} "
            f"[dim]({len(hosts)} hosts: {lxc} LXC, {vm} VM, {xoa} XCP-ng)[/dim]"
        )

    backup_dir = fleet_cache_dir(root) / "hosts-backups"
    backup_dir.mkdir(exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup_file = backup_dir / f"hosts.{timestamp}.json"
    backup_file.write_text(output)

    # Refresh the CLI catalog alongside (ADR-097) — same source eval,
    # already warm, so this is nearly free here and keeps the two
    # projections aging together.
    from .config import CATALOG_RELPATH, _materialize_catalog
    _materialize_catalog(root, root / CATALOG_RELPATH)

    return hosts_file


@inventory.command("generate")
def generate():
    """Materialise .cache/fleet/hosts.json from the Nix fleet module.

    Runs ``nix build .#hostsJson`` and copies the output to
    ``.cache/fleet/hosts.json`` (with a timestamped backup).  Use
    ``fleet inventory diff`` to compare declared state against
    live Proxmox state.
    """
    generate_hosts_json()


@inventory.command("show")
def show():
    """Display current hosts inventory as a rich table.

    Reads ``.cache/fleet/hosts.json`` and prints each host's VMID, routable IP
    (vmbr0), internal IP (vmbr1), and tags.
    """
    root = _find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"

    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found — run 'fleet inventory generate' first")
        sys.exit(1)

    with open(hosts_file) as f:
        hosts = json.load(f)

    table = Table(title="Host Inventory", show_header=True, header_style="bold cyan")
    table.add_column("Name", style="green")
    table.add_column("VMID", justify="right")
    table.add_column("IP (vmbr0)")
    table.add_column("Internal (vmbr1)")
    table.add_column("Tags")

    for name, meta in sorted(hosts.items()):
        ip = meta.get("ip", "")
        internal_ip = meta.get("internal_ip", "")
        table.add_row(
            name,
            str(meta.get("vmid", "")),
            ip if ip else "[dim]none[/dim]",
            internal_ip if internal_ip else "[dim]none[/dim]",
            ", ".join(meta.get("tags", [])) or "[dim]-[/dim]",
        )

    console.print(table)
    console.print(f"\n[dim]{len(hosts)} hosts total[/dim]")


@inventory.command("diff")
def diff():
    """Show drift between declared (fleet) and live (PVE API) state.

    Declared state comes from the Nix fleet module (``.#hostsJson``).
    Live state comes from the Proxmox REST API (container + VM config +
    agent interfaces).  Reports per-host: VMID mismatches, IP drift,
    MAC drift, and hosts that exist on one side but not the other.

    Read-only — never writes .cache/fleet/hosts.json.  Use
    ``fleet inventory generate`` to refresh the on-disk inventory from
    fleet.
    """
    root = _find_project_root()

    # Declared: nix build + parse
    console.print("Loading declared state from [cyan]fleet.hostsJson[/cyan]…")
    try:
        result = subprocess.run(
            ["nix", "build", ".#hostsJson", "--no-link", "--print-out-paths"],
            cwd=root, capture_output=True, text=True, check=True, timeout=120,
        )
        declared = json.loads(Path(result.stdout.strip()).read_text())
    except subprocess.CalledProcessError as exc:
        console.print(f"[red]nix build failed:[/red]\n{exc.stderr}")
        sys.exit(1)

    # Live: PVE API scrape (the old _query_pve_api path, but here for
    # diagnosis only — never written back to hosts.json).
    console.print("Querying [cyan]Proxmox API[/cyan] for live state…")
    hosts_by_vmid = {h["vmid"]: h.get("pve_type", "lxc") for h in declared.values()}
    live_data = _query_pve_api(hosts_by_vmid)

    drift_rows: list[tuple[str, str, str, str]] = []
    for name, dh in sorted(declared.items()):
        vmid = dh["vmid"]
        live = live_data.get(vmid)
        if live is None:
            drift_rows.append((name, "missing-in-proxmox", dh["ip"], "-"))
            continue
        if dh["ip"] and live["ip"] and dh["ip"] != live["ip"]:
            drift_rows.append((name, "ip-drift", dh["ip"], live["ip"]))
        if dh["internal_ip"] and live["internal_ip"] and dh["internal_ip"] != live["internal_ip"]:
            drift_rows.append((name, "internal_ip-drift", dh["internal_ip"], live["internal_ip"]))

    if not drift_rows:
        console.print("[green]No drift.[/green] Declared matches live.")
        return

    t = Table(title="Fleet drift — declared vs live", show_header=True, header_style="bold yellow")
    t.add_column("Host", style="cyan")
    t.add_column("Kind", style="magenta")
    t.add_column("Declared")
    t.add_column("Live", style="red")
    for row in drift_rows:
        t.add_row(*row)
    console.print(t)
    sys.exit(2)


@inventory.command("scan")
@click.option("--subnet", default=None,
              help="CIDR subnet to scan (default: [network].internal_cidr "
                   "from the fleet catalog).")
@click.option("--workers", default=100,
              help="Maximum number of parallel ping workers (default: 100).")
def scan(subnet: str | None, workers: int):
    """Scan a subnet for used and available IPs via parallel ping + ARP.

    Pings every host in the subnet concurrently, supplements results
    from the ARP cache, and performs reverse DNS lookups on discovered
    addresses.
    """
    import ipaddress
    import socket
    from concurrent.futures import ThreadPoolExecutor, as_completed

    if not subnet:
        from .config import require
        subnet = require("network.internal_cidr",
                         "Internal network CIDR, e.g. internal_cidr = "
                         "\"192.0.2.0/24\" (or pass --subnet).")

    network = ipaddress.ip_network(subnet, strict=False)
    all_hosts = [str(ip) for ip in network.hosts()]

    def ping(ip: str) -> bool:
        try:
            result = subprocess.run(
                ["ping", "-c", "1", "-W", "1", ip],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return result.returncode == 0
        except OSError:
            return False

    def reverse_dns(ip: str) -> str:
        try:
            name, _, _ = socket.gethostbyaddr(ip)
            return name
        except (socket.herror, OSError):
            return ""

    console.print(f"Scanning [bold]{len(all_hosts)}[/bold] hosts in {subnet}...")

    used: set[str] = set()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(ping, ip): ip for ip in all_hosts}
        for future in as_completed(futures):
            if future.result():
                used.add(futures[future])

    # ARP cache
    try:
        out = subprocess.check_output(["ip", "neigh"], stderr=subprocess.DEVNULL, text=True)
        base_prefix = subnet.rsplit(".", 1)[0] + "."
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 5 and "FAILED" not in parts:
                ip = parts[0]
                if ip.startswith(base_prefix):
                    used.add(ip)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    used_sorted = sorted(used, key=ipaddress.ip_address)
    available = [ip for ip in all_hosts if ip not in used]

    # Reverse DNS
    hostnames: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(reverse_dns, ip): ip for ip in used_sorted}
        for future in as_completed(futures):
            hostnames[futures[future]] = future.result()

    table = Table(title=f"Used IPs in {subnet}", show_header=True, header_style="bold cyan")
    table.add_column("IP", style="green")
    table.add_column("Hostname")

    for ip in used_sorted:
        hostname = hostnames.get(ip, "")
        table.add_row(ip, hostname or "[dim]unknown[/dim]")

    console.print(table)
    console.print(f"\n[bold]{len(used)}[/bold] in use, [bold]{len(available)}[/bold] available")
