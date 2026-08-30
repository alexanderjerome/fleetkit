"""Shared Proxmox VE API client using proxmoxer.

Uses the REST API (port 8006) instead of SSH, providing reliable
connectivity even when SSH is flaky or unavailable.

Credentials come from SOPS (loaded by main._setup_env), same env vars
the terranix bw_proxmox provider consumes:
  PROXMOX_VE_ENDPOINT  — https://192.0.2.2:8006
  PROXMOX_VE_USERNAME  — root@pam
  PROXMOX_VE_PASSWORD  — password
  PROXMOX_VE_INSECURE  — true (skip TLS verify)
"""
from __future__ import annotations

import os
import sys
import time
from urllib.parse import urlparse

from proxmoxer import ProxmoxAPI
from rich.console import Console

console = Console()

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

_client: ProxmoxAPI | None = None


def get_client() -> ProxmoxAPI:
    """Create or return a cached proxmoxer client from environment variables."""
    global _client
    if _client is not None:
        return _client

    endpoint = os.environ.get("PROXMOX_VE_ENDPOINT", "")
    username = os.environ.get("PROXMOX_VE_USERNAME", "root@pam")
    password = os.environ.get("PROXMOX_VE_PASSWORD", "")
    insecure = os.environ.get("PROXMOX_VE_INSECURE", "false").lower() in ("true", "1", "yes")

    if not endpoint:
        console.print("[red]ERROR:[/red] PROXMOX_VE_ENDPOINT not set (source .env)")
        sys.exit(1)
    if not password:
        console.print("[red]ERROR:[/red] PROXMOX_VE_PASSWORD not set (source .env)")
        sys.exit(1)

    parsed = urlparse(endpoint)
    host = parsed.hostname or endpoint
    port = parsed.port or 8006

    _client = ProxmoxAPI(
        host,
        port=port,
        user=username,
        password=password,
        verify_ssl=not insecure,
        timeout=30,
    )
    return _client


def get_host() -> str:
    """Return the PVE host IP from environment."""
    endpoint = os.environ.get("PROXMOX_VE_ENDPOINT", "")
    if not endpoint:
        return ""
    parsed = urlparse(endpoint)
    return parsed.hostname or endpoint


# ---------------------------------------------------------------------------
# Container queries
# ---------------------------------------------------------------------------

def resolve_node(api: ProxmoxAPI, vmid: int) -> str:
    """Node hosting VMID, from /cluster/resources.

    The fleet moved from a single PVE host (node name "pve") to a
    multi-node cluster; the node="pve" defaults below are only kept as
    a fallback for the old mono-host layout.
    """
    for res in api.cluster.resources.get(type="vm"):
        if res.get("vmid") == vmid:
            return res["node"]
    return "pve"


def list_containers(api: ProxmoxAPI, node: str = "pve") -> list[dict]:
    """List all LXC containers on a node."""
    return api.nodes(node).lxc.get()


def get_container_config(api: ProxmoxAPI, vmid: int, node: str = "pve") -> dict:
    """Get container configuration."""
    return api.nodes(node).lxc(vmid).config.get()


def get_container_interfaces(api: ProxmoxAPI, vmid: int, node: str = "pve") -> list[dict]:
    """Get container network interfaces."""
    try:
        return api.nodes(node).lxc(vmid).interfaces.get()
    except Exception:
        return []


def get_container_status(api: ProxmoxAPI, vmid: int, node: str = "pve") -> dict:
    """Get container current status."""
    return api.nodes(node).lxc(vmid).status.current.get()


# ---------------------------------------------------------------------------
# Container lifecycle (API-native)
# ---------------------------------------------------------------------------

def start_container(api: ProxmoxAPI, vmid: int, node: str = "pve") -> str:
    """Start a container. Returns UPID task string."""
    return api.nodes(node).lxc(vmid).status.start.post()


def stop_container(api: ProxmoxAPI, vmid: int, node: str = "pve") -> str:
    """Stop a container. Returns UPID task string."""
    return api.nodes(node).lxc(vmid).status.stop.post()


def shutdown_container(api: ProxmoxAPI, vmid: int, node: str = "pve",
                       timeout: int = 60) -> str:
    """Gracefully shutdown a container."""
    return api.nodes(node).lxc(vmid).status.shutdown.post(timeout=timeout)


def reboot_container(api: ProxmoxAPI, vmid: int, node: str = "pve") -> str:
    """Reboot a container."""
    return api.nodes(node).lxc(vmid).status.reboot.post()


# ---------------------------------------------------------------------------
# Task tracking
# ---------------------------------------------------------------------------

def wait_for_task(api: ProxmoxAPI, upid: str, node: str = "pve",
                  timeout: int = 120, poll_interval: float = 2.0) -> dict:
    """Wait for a PVE task to complete. Returns task status dict."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = api.nodes(node).tasks(upid).status.get()
        if status.get("status") == "stopped":
            return status
        time.sleep(poll_interval)
    return {"status": "timeout", "upid": upid}


# ---------------------------------------------------------------------------
# Config extraction helpers
# ---------------------------------------------------------------------------

def extract_ip_from_config(config: dict) -> str:
    """Extract first static IP from container config (checks net0, net1, ...)."""
    for i in range(4):
        net_key = f"net{i}"
        net_val = config.get(net_key, "")
        for part in net_val.split(","):
            if part.startswith("ip="):
                addr = part.split("=", 1)[1]
                if addr and addr != "dhcp":
                    return addr.split("/")[0]
    return ""


def extract_mac_from_config(config: dict, iface: str = "net0") -> str:
    """Extract MAC address from container config."""
    net_val = config.get(iface, "")
    for part in net_val.split(","):
        if part.startswith("hwaddr="):
            return part.split("=", 1)[1]
    return ""


def extract_net_config(config: dict) -> dict[str, dict]:
    """Extract all network interface configs as structured dicts."""
    nets: dict[str, dict] = {}
    for i in range(4):
        key = f"net{i}"
        raw = config.get(key, "")
        if not raw:
            continue
        parsed: dict[str, str] = {}
        for part in raw.split(","):
            if "=" in part:
                k, v = part.split("=", 1)
                parsed[k] = v
        nets[f"eth{i}"] = parsed
    return nets
