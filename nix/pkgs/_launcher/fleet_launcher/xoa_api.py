"""XOA REST API client — read-only discovery for `fleet inventory generate`.

XCP-ng VMs DHCP their NICs (the Vates provider's `xenorchestra_vm`
doesn't have a Proxmox-style `ipconfig0` static-IP injection
mechanism), so fleet.nix declares `ip = ""` / `internal_ip = ""` for
XCP-ng entries and we patch the live IPs in here.

Credentials come from main._setup_env via SOPS:
  XOA_URL       — https://<xoa-host>  (REST endpoint; converted from
                  wss:// at env-load time)
  XOA_TOKEN     — service-account auth token
  XOA_INSECURE  — true (skip TLS verify; XOA self-signed cert)

Only GET endpoints are used. Mutations (vm.create, disk.import, etc.)
go through xo-cli or terranix; this module is strictly read-only.
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

from rich.console import Console

console = Console()


def _request(path: str, fields: list[str] | None = None) -> object | None:
    """GET /rest/v0/<path>?fields=...; return parsed JSON or None on failure."""
    url = os.environ.get("XOA_URL", "")
    token = os.environ.get("XOA_TOKEN", "")
    if not url or not token:
        return None

    insecure = os.environ.get("XOA_INSECURE", "false").lower() in ("true", "1", "yes")
    ctx = ssl._create_unverified_context() if insecure else None

    target = url + "/rest/v0/" + path.lstrip("/")
    if fields:
        target += ("&" if "?" in target else "?") + "fields=" + ",".join(fields)

    req = urllib.request.Request(target, headers={"Cookie": f"authenticationToken={token}"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        console.print(f"[yellow]Warning:[/yellow] XOA REST {path} failed: {exc}")
        return None


def list_vms_by_name() -> dict[str, dict] | None:
    """Return {name_label: vm_metadata} for every VM on the pool.

    Each value includes the VM's UUID, addresses dict (per-NIC IPs from
    qemu-guest-agent), tags, and power_state. Returns None if XOA is
    unreachable (caller treats that as "no live data; keep declared
    fleet values").
    """
    vms = _request("vms", fields=[
        "name_label", "uuid", "addresses", "mainIpAddress",
        "power_state", "tags", "VIFs",
    ])
    if not isinstance(vms, list):
        return None
    return {vm["name_label"]: vm for vm in vms if isinstance(vm, dict) and "name_label" in vm}


def list_networks_by_uuid() -> dict[str, dict] | None:
    """Return {uuid: network_metadata} so callers can map VIFs → networks.

    Used to distinguish a VM's WAN-side IP from an internal-side IP by
    comparing the VIF's attached network against the fleet's named
    xo-network-* entries.
    """
    nets = _request("networks", fields=["name_label", "uuid", "bridge"])
    if not isinstance(nets, list):
        return None
    return {n["uuid"]: n for n in nets if isinstance(n, dict) and "uuid" in n}


def list_vifs_by_vm() -> dict[str, list[dict]] | None:
    """Return {vm_uuid: [vif_metadata, ...]} so callers can join VIF→VM."""
    vifs = _request("vifs", fields=["uuid", "MAC", "$VM", "$network"])
    if not isinstance(vifs, list):
        return None
    by_vm: dict[str, list[dict]] = {}
    for vif in vifs:
        if not isinstance(vif, dict):
            continue
        vm_uuid = vif.get("$VM") or vif.get("VM")
        if vm_uuid:
            by_vm.setdefault(vm_uuid, []).append(vif)
    return by_vm


def discover_xo_ips(
    declared: dict[str, dict],
    wan_network_uuid: str | None = None,
    internal_network_uuid: str | None = None,
) -> dict[str, dict]:
    """Patch `ip` and `internal_ip` into XCP-ng/XOA-managed declared entries.

    For each entry whose `provider_instance` starts with `xen-orchestra.`
    AND whose `ip` / `internal_ip` are empty (declared as such in
    fleet.nix), query XOA for a VM with a matching `name_label`. If
    found, fill in:

      - `ip` = first IPv4 on the WAN NIC (resolved by VIF→network match
        when `wan_network_uuid` is provided, else first non-loopback
        IPv4 in `addresses`).
      - `internal_ip` = first IPv4 on the internal NIC, when an
        `internal_network_uuid` is provided.

    Never overwrites a non-empty declared value — that's a drift signal
    for `fleet inventory diff` to surface, not something this generator
    should silently clobber.
    """
    xo_entries = [
        (name, meta) for name, meta in declared.items()
        if str(meta.get("provider_instance", "")).startswith("xen-orchestra.")
        and (not meta.get("ip") or not meta.get("internal_ip"))
    ]
    if not xo_entries:
        return declared

    vms_by_name = list_vms_by_name()
    if vms_by_name is None:
        # XOA unreachable — degrade gracefully, leave declared values alone.
        return declared

    vifs_by_vm = list_vifs_by_vm() or {}

    patched = 0
    for name, meta in xo_entries:
        vm = vms_by_name.get(name)
        if vm is None:
            continue
        addresses = vm.get("addresses") or {}
        vm_vifs = vifs_by_vm.get(vm.get("uuid", ""), [])

        # Map VIF index → network UUID so we can pick which IP is WAN vs internal.
        vif_networks = {i: v.get("$network") for i, v in enumerate(vm_vifs)}

        wan_ip = ""
        internal_ip = ""
        for key, value in addresses.items():
            # XOA's `addresses` keys look like "0/ipv4/0", "1/ipv4/0", etc.
            # The first segment is the VIF index.
            if not isinstance(value, str) or ":" in value:
                continue  # skip IPv6
            parts = key.split("/")
            if len(parts) < 2 or parts[1] != "ipv4":
                continue
            try:
                vif_index = int(parts[0])
            except ValueError:
                continue
            net_uuid = vif_networks.get(vif_index)
            if wan_network_uuid and net_uuid == wan_network_uuid:
                wan_ip = wan_ip or value
            elif internal_network_uuid and net_uuid == internal_network_uuid:
                internal_ip = internal_ip or value
            elif not wan_ip:
                wan_ip = value  # fallback when network UUIDs aren't supplied

        # Patch only empty declared fields.
        if not meta.get("ip") and wan_ip:
            meta["ip"] = wan_ip
            patched += 1
        if not meta.get("internal_ip") and internal_ip:
            meta["internal_ip"] = internal_ip
            patched += 1

    if patched:
        console.print(f"[green]Patched[/green] {patched} XCP-ng IP field(s) from live XOA")
    return declared
