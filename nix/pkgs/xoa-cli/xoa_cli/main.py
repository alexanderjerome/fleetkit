"""xoa-cli — Xen Orchestra operator CLI (INFRA-172).

Standalone split of the sk launcher's `sk xoa` group, packaged as a nix
application (nix/pkgs/xoa-cli) so nix config / fleet tooling / the future
MCP endpoint (INFRA-166) can call it directly. `sk xoa …` remains a thin
shim over this package.

Reads go over the XO REST API; mutations go over the JSON-RPC websocket
API (same protocol as upstream xo-cli) — see api.py for why.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import click
from rich.console import Console

from .api import XoError, XoRest, XoRpc

console = Console()

GIB = 1024 ** 3


def _die(exc: Exception) -> None:
    console.print(f"[red]ERROR:[/red] {exc}")
    sys.exit(1)


@click.group()
@click.version_option(package_name="xoa-cli", prog_name="xoa-cli")
def xoa() -> None:
    """XCP-ng / XOA operator commands."""


# ── Discovery (read-only) ─────────────────────────────────────────


@xoa.command("list-srs")
@click.option("--iso-only", is_flag=True, help="Filter to ISO SRs only.")
def list_srs(iso_only: bool) -> None:
    """List storage repositories on the XOA pool."""
    try:
        rows = XoRest().get(
            "srs",
            fields=["name_label", "uuid", "SR_type", "content_type",
                    "shared", "size", "physical_usage"])
    except XoError as exc:
        _die(exc)
    rows = [r for r in rows if isinstance(r, dict)]
    if iso_only:
        rows = [r for r in rows
                if r.get("content_type") == "iso" or r.get("SR_type") == "iso"]
    console.print(f"[bold]{'name_label':<28} {'type':<8} {'content':<8} {'shared':<6} "
                  f"{'size GB':>8} {'used GB':>8}  uuid[/bold]")
    for sr in sorted(rows, key=lambda x: x.get("name_label", "")):
        console.print(
            f"{sr.get('name_label', '?'):<28} "
            f"{sr.get('SR_type', '?'):<8} "
            f"{sr.get('content_type', '?'):<8} "
            f"{'yes' if sr.get('shared') else 'no':<6} "
            f"{(sr.get('size') or 0) / GIB:>8.0f} "
            f"{(sr.get('physical_usage') or 0) / GIB:>8.0f}  "
            f"[dim]{sr.get('uuid', '?')}[/dim]")


@xoa.command("list-networks")
def list_networks() -> None:
    """List networks on the XOA pool (bridge name_labels + UUIDs)."""
    try:
        rows = XoRest().get("networks", fields=["name_label", "uuid", "bridge", "MTU"])
    except XoError as exc:
        _die(exc)
    console.print(f"[bold]{'name_label':<50} {'bridge':<10} {'MTU':<6}  uuid[/bold]")
    for n in sorted([r for r in rows if isinstance(r, dict)],
                    key=lambda x: x.get("name_label", "")):
        console.print(
            f"{n.get('name_label', '?'):<50} "
            f"{n.get('bridge', '?'):<10} "
            f"{str(n.get('MTU', '?')):<6}  "
            f"[dim]{n.get('uuid', '?')}[/dim]")


@xoa.command("list-templates")
@click.option("--filter", "name_filter", default="",
              help="Substring filter on name_label.")
def list_templates(name_filter: str) -> None:
    """List VM templates on the XOA pool."""
    try:
        rows = XoRest().get("vm-templates", fields=["name_label", "uuid", "tags"])
    except XoError as exc:
        _die(exc)
    rows = [r for r in rows if isinstance(r, dict)]
    if name_filter:
        rows = [r for r in rows
                if name_filter.lower() in r.get("name_label", "").lower()]
    console.print(f"[bold]{'name_label':<50} tags  uuid[/bold]")
    for t in sorted(rows, key=lambda x: x.get("name_label", "")):
        tags = ", ".join(t.get("tags") or [])
        console.print(
            f"{t.get('name_label', '?'):<50} "
            f"{tags or '-':<20} "
            f"[dim]{t.get('uuid', '?')}[/dim]")


@xoa.command("list-isos")
@click.option("--sr", "sr_name", default="",
              help="Filter to ISOs on a specific SR by name_label.")
def list_isos(sr_name: str) -> None:
    """List ISO VDIs (existing ISOs across all ISO SRs)."""
    rest = XoRest()
    try:
        srs = rest.get("srs", fields=["name_label", "uuid", "SR_type", "content_type"])
        vdis = rest.get("vdis", fields=["name_label", "uuid", "$SR", "size"])
    except XoError as exc:
        _die(exc)
    iso_sr_by_uuid = {
        s.get("uuid"): s.get("name_label", "?")
        for s in srs
        if isinstance(s, dict)
        and (s.get("content_type") == "iso" or s.get("SR_type") == "iso")
        and (not sr_name or s.get("name_label") == sr_name)}
    iso_vdis = [v for v in vdis
                if isinstance(v, dict) and v.get("$SR") in iso_sr_by_uuid]
    console.print(f"[bold]{'name_label':<48} {'SR':<22} {'size MB':>10}  uuid[/bold]")
    for v in sorted(iso_vdis, key=lambda x: x.get("name_label", "")):
        console.print(
            f"{v.get('name_label', '?'):<48} "
            f"{iso_sr_by_uuid.get(v.get('$SR'), '?'):<22} "
            f"{(v.get('size') or 0) / 1024**2:>10.0f}  "
            f"[dim]{v.get('uuid', '?')}[/dim]")


@xoa.command("sr-scan")
@click.argument("sr_uuid")
def sr_scan(sr_uuid: str) -> None:
    """Trigger an SR scan so new ISOs / VDIs become visible."""
    try:
        with XoRpc() as rpc:
            rpc.call("sr.scan", {"id": sr_uuid})
    except XoError as exc:
        _die(exc)
    console.print(f"[green]sr.scan triggered[/green] for {sr_uuid}")


# ── VM lifecycle ──────────────────────────────────────────────────


@xoa.command("vm-info")
@click.argument("vm")
def vm_info(vm: str) -> None:
    """Show a VM's power state, memory, vCPUs, IPs, and disks."""
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        disks = rest.vm_disks(rec["uuid"])
    except XoError as exc:
        _die(exc)
    mem = rec.get("memory") or {}
    mem_str = (f"{(mem.get('size') or 0) / GIB:.1f}G "
               f"(static max {(mem.get('static', [0, 0])[1] or 0) / GIB:.1f}G, "
               f"dynamic {[round((x or 0) / GIB, 1) for x in mem.get('dynamic', [])]}G)"
               if isinstance(mem, dict) else str(mem))
    console.print(f"[bold]{vm}[/bold]  uuid={rec.get('uuid')}")
    console.print(f"  power_state : {rec.get('power_state')}")
    console.print(f"  vCPUs       : {(rec.get('CPUs') or {}).get('number', '?')}")
    console.print(f"  memory      : {mem_str}")
    console.print(f"  main IP     : {rec.get('mainIpAddress', '-')}")
    console.print(f"  tags        : {', '.join(rec.get('tags') or []) or '-'}")
    for d in disks:
        console.print(f"  disk '{d['name_label']}' : {d['size'] / GIB:.1f}G "
                      f"(device {d['device']}, vdi {d['vdi_uuid']})")


@xoa.command("vm-halt")
@click.argument("vm")
@click.option("--force", is_flag=True, help="Hard stop instead of clean shutdown.")
def vm_halt(vm: str, force: bool) -> None:
    """Shut a VM down (clean by default) and wait until Halted."""
    from .reconcile import _wait_power_state
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        if rec.get("power_state") == "Halted":
            console.print(f"[green]{vm} already Halted.[/green]")
            return
        with XoRpc() as rpc:
            rpc.call("vm.stop", {"id": rec["uuid"], "force": force}, timeout=300)
        _wait_power_state(rest, vm, "Halted")
    except XoError as exc:
        _die(exc)
    console.print(f"[green]{vm} Halted.[/green]")


@xoa.command("vm-start")
@click.argument("vm")
def vm_start(vm: str) -> None:
    """Start a VM and wait until Running."""
    from .reconcile import _wait_power_state
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        if rec.get("power_state") == "Running":
            console.print(f"[green]{vm} already Running.[/green]")
            return
        with XoRpc() as rpc:
            rpc.call("vm.start", {"id": rec["uuid"]}, timeout=300)
        _wait_power_state(rest, vm, "Running")
    except XoError as exc:
        _die(exc)
    console.print(f"[green]{vm} Running.[/green]")


@xoa.command("vm-snapshot")
@click.argument("vm")
@click.option("--name", "snap_name", default="",
              help="Snapshot name_label (default: xoa-cli-<timestamp>).")
def vm_snapshot(vm: str, snap_name: str) -> None:
    """Snapshot a VM (works Running or Halted). Prints the snapshot id."""
    import datetime
    if not snap_name:
        snap_name = "xoa-cli-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        with XoRpc() as rpc:
            snap_id = rpc.call("vm.snapshot",
                               {"id": rec["uuid"], "name": snap_name}, timeout=600)
    except XoError as exc:
        _die(exc)
    console.print(f"[green]snapshot created[/green] '{snap_name}' → {snap_id}")


@xoa.command("vm-set-memory")
@click.argument("vm")
@click.argument("memory_gb", type=int)
def vm_set_memory(vm: str, memory_gb: int) -> None:
    """Set a VM's memory to MEMORY_GB GiB (static max — VM should be Halted)."""
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        if rec.get("power_state") != "Halted":
            console.print(
                f"[red]{vm}: power_state={rec.get('power_state')} — raising static "
                f"max needs the VM Halted. Halt it first (xoa-cli vm-halt {vm}).[/red]")
            sys.exit(1)
        before = (rec.get("memory") or {}).get("size", 0)
        with XoRpc() as rpc:
            rpc.call("vm.set", {"id": rec["uuid"], "memory": memory_gb * GIB},
                     timeout=120)
        after_rec = rest.vm_by_name(vm)
        after = (after_rec.get("memory") or {}).get("size", 0)
    except XoError as exc:
        _die(exc)
    console.print(f"[green]{vm} memory[/green] {before / GIB:.1f}G → {after / GIB:.1f}G")


# ── Disk sizing ───────────────────────────────────────────────────


@xoa.command("resize-disk")
@click.argument("vm")
@click.argument("disk_name")
@click.argument("size_gb", type=int)
@click.option("--halt", is_flag=True,
              help="Clean-shutdown the VM first, grow, then boot it again.")
def resize_disk(vm: str, disk_name: str, size_gb: int, halt: bool) -> None:
    """Grow VM's disk DISK_NAME to SIZE_GB GiB (absolute target).

    Uses JSON-RPC `vdi.set` (the REST PATCH is a silent no-op — INFRA-147)
    and therefore requires the VM Halted; --halt automates the
    shutdown→grow→boot cycle. Refuses to shrink; no-op when equal.

    Prefer `reconcile-disks` for fleet hosts — it derives the target from
    the fleet declaration (size_gb + size_add_gb) instead of a CLI number.
    """
    from .reconcile import _wait_power_state
    rest = XoRest()
    try:
        rec = rest.vm_by_name(vm)
        disks = [d for d in rest.vm_disks(rec["uuid"])
                 if d["name_label"] == disk_name]
        if not disks:
            all_names = [d["name_label"] for d in rest.vm_disks(rec["uuid"])]
            console.print(f"[red]no disk named '{disk_name}' on {vm}[/red] "
                          f"(available: {all_names})")
            sys.exit(1)
        disk = disks[0]
        target = size_gb * GIB
        if target < disk["size"]:
            console.print(f"[red]refusing to shrink[/red] '{disk_name}' "
                          f"({disk['size'] / GIB:.1f}G → {size_gb}G)")
            sys.exit(1)
        if target == disk["size"]:
            console.print(f"[green]no-op:[/green] '{disk_name}' already {size_gb}G")
            return

        power = rec.get("power_state")
        started_halt = False
        if power not in ("Halted", "Running"):
            console.print(f"[red]{vm}: unexpected power_state '{power}' — refusing.[/red]")
            sys.exit(1)
        if power == "Running":
            if not halt:
                console.print(f"[red]{vm} is Running — VDI resize needs it Halted. "
                              f"Re-run with --halt.[/red]")
                sys.exit(1)
            console.print(f"{vm}: clean shutdown…")
            with XoRpc() as rpc:
                rpc.call("vm.stop", {"id": rec["uuid"]}, timeout=300)
            _wait_power_state(rest, vm, "Halted")
            started_halt = True

        console.print(f"{vm}:{disk_name}: {disk['size'] / GIB:.1f}G → {size_gb}G "
                      f"(vdi {disk['vdi_uuid']})…")
        with XoRpc() as rpc:
            rpc.call("vdi.set", {"id": disk["vdi_uuid"], "size": target}, timeout=300)
        after = rest.get(f"vdis/{disk['vdi_uuid']}", fields=["size"])
        after_size = int(after.get("size") or 0) if isinstance(after, dict) else 0
        if after_size < target:
            console.print(f"[red]vdi.set returned but size is "
                          f"{after_size / GIB:.1f}G (wanted {size_gb}G)[/red]")
            sys.exit(1)
        console.print(f"[green]grown[/green] → {after_size / GIB:.1f}G (verified)")

        if started_halt:
            console.print(f"{vm}: booting…")
            with XoRpc() as rpc:
                rpc.call("vm.start", {"id": rec["uuid"]}, timeout=300)
            _wait_power_state(rest, vm, "Running")
            console.print(f"[green]{vm} Running again.[/green]")
    except XoError as exc:
        _die(exc)


@xoa.command("reconcile-disks")
@click.argument("hosts", nargs=-1, required=True)
@click.option("--halt", is_flag=True,
              help="Allowed to shutdown→grow→boot Running VMs.")
@click.option("--dry-run", is_flag=True, help="Plan only; no mutations.")
@click.option("--flake", default=".",
              help="Flake ref to eval #fleetManifest from (default: cwd).")
def reconcile_disks(hosts: tuple[str, ...], halt: bool, dry_run: bool,
                    flake: str) -> None:
    """Reconcile live VDI sizes with the fleet declaration for HOSTS.

    Target per disk = size_gb (terranix create-time base) + size_add_gb
    (imperative grow layer, INFRA-172/ADR-081). Grows when live < target,
    never shrinks, reports drift when live > target.
    """
    from .reconcile import load_manifest, reconcile_host
    try:
        manifest = load_manifest(flake)
    except XoError as exc:
        _die(exc)
    all_ok = True
    for host in hosts:
        try:
            all_ok = reconcile_host(host, manifest, halt=halt,
                                    dry_run=dry_run) and all_ok
        except XoError as exc:
            console.print(f"[red]{host}: {exc}[/red]")
            all_ok = False
    sys.exit(0 if all_ok else 1)


@xoa.command("build-template")
@click.option("--image", required=True,
              type=click.Path(exists=True, dir_okay=False, resolve_path=True),
              help="Disk image (qcow2 or vhd) to become the template's root disk.")
@click.option("--name", "template_name", required=True,
              help="name_label for the resulting template (versioned, e.g. debian13-docker-bootstrap-v1).")
@click.option("--sr-name", default="big_space", show_default=True,
              help="SR name_label the root VDI lands on.")
@click.option("--network-name", default="Pool-wide network associated with eth3",
              show_default=True, help="Network name_label for the template's VIF.")
def build_template(image: str, template_name: str, sr_name: str,
                   network_name: str) -> None:
    """Disk image → XO VM template (ADR-022 runbook, one shot).

    qcow2 inputs are converted to VHD first (qemu-img, with a
    `nix shell nixpkgs#qemu` fallback). The VHD is streamed into the SR
    via REST, wrapped in a staging VM (cloned from the neutral "Other
    install media" base), set to boot from disk, and converted to a
    template. This is the same sequence that produced
    nixos-fleet-bootstrap-v11; packaged per ADR-022's fast-follow note.
    """
    import shutil
    import subprocess
    import tempfile

    try:
        rest = XoRest()

        # ── Refuse to clobber an existing template ──
        templates = rest.get("vm-templates", fields=["name_label", "uuid"])
        assert isinstance(templates, list)
        if any(t.get("name_label") == template_name for t in templates
               if isinstance(t, dict)):
            raise XoError(f"template '{template_name}' already exists — "
                          "templates are versioned, pick a new name")

        # ── Convert to RAW ──
        # Upload as raw (raw=true), NOT VHD: XO's REST import sizes the
        # VDI by Content-Length. For a (sparse) VHD that's the FILE size,
        # not the virtual disk size, so the VDI comes out truncated — the
        # backup GPT lands past disk-end and EDK2 refuses to boot the
        # "invalid" GPT (INFRA-194 debug: 3 GiB VHD → 2.03 GiB VDI).
        # Raw makes Content-Length == virtual size by construction.
        with open(image, "rb") as fh:
            magic = fh.read(8)
        fmt = "qcow2" if magic[:4] == b"QFI\xfb" else (
            "vpc" if magic == b"conectix" else "raw")
        raw = image
        if fmt != "raw":
            raw = str(Path(tempfile.gettempdir()) / f"{template_name}.raw")
            console.print(f"converting {fmt} → raw at {raw} …")
            conv = ["qemu-img", "convert", "-f", fmt, "-O", "raw",
                    image, raw]
            if shutil.which("qemu-img") is None:
                conv = ["nix", "shell", "nixpkgs#qemu", "--command"] + conv
            subprocess.run(conv, check=True)

        # ── Resolve XO primitives ──
        def _uuid(collection: str, label: str) -> str:
            objs = rest.get(collection, fields=["name_label", "uuid"])
            assert isinstance(objs, list)
            matches = [o["uuid"] for o in objs if isinstance(o, dict)
                       and o.get("name_label") == label]
            if len(matches) != 1:
                raise XoError(f"{collection}: {len(matches)} objects named "
                              f"'{label}' — need exactly 1")
            return matches[0]

        sr = _uuid("srs", sr_name)
        net = _uuid("networks", network_name)
        base = _uuid("vm-templates", "Other install media")
        pools = rest.get("pools", fields=["uuid"])
        assert isinstance(pools, list) and pools
        pool = pools[0]["uuid"]
        console.print(f"sr={sr} network={net} base={base} pool={pool}")

        # ── Upload the raw image as a VDI ──
        size_gib = os.path.getsize(raw) / GIB
        console.print(f"uploading {raw} ({size_gib:.2f} GiB raw) to {sr_name} …")
        vdi = rest.import_vdi(sr, f"{template_name}-disk", raw, raw=True)
        console.print(f"VDI {vdi}")

        # ── Wrap in a staging VM, boot-from-disk, convert ──
        with XoRpc() as rpc:
            vm = rpc.call("vm.create", {
                "name_label": f"{template_name}-staging",
                "template": f"{pool}-{base}",
                "bootAfterCreate": False,
                "existingDisks": {},
                "VIFs": [{"network": net}],
            })
            console.print(f"staging VM {vm}")
            rpc.call("vm.attachDisk", {
                "vm": vm, "vdi": vdi,
                "bootable": True, "position": "0", "mode": "RW",
            })
            rpc.call("vm.setBootOrder", {"vm": vm, "order": "c"})
            rpc.call("vm.set", {"id": vm, "name_label": template_name})
            rpc.call("vm.convertToTemplate", {"id": vm})

        console.print(f"[green]template '{template_name}' created.[/green] "
                      "Reference it via a fleet.resources xo-template entry.")
    except (XoError, subprocess.CalledProcessError, AssertionError) as exc:
        _die(exc)


def main() -> None:
    xoa()


if __name__ == "__main__":
    main()
