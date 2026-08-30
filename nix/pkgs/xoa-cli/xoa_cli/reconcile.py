"""reconcile-disks — imperative VDI grow driven by the declarative manifest.

INFRA-172 / ADR-081. The fleet declaration for an `xcpng.vm` disk carries:

  size_gb      — base size, what terranix provisions at CREATE time
                 (ForceNew in the provider; ignore_changes afterwards)
  size_add_gb  — additional GiB layered on top, applied imperatively
                 by THIS tool (never by terraform)

Target = size_gb + size_add_gb. The reconciler grows the live VDI via the
XO JSON-RPC `vdi.set` when actual < target. Guardrails:

  * NEVER shrinks. actual > target is reported as drift, not "fixed".
  * no-op when actual == target.
  * VDI resize requires the VM Halted (XO REST PATCH is a silent no-op
    and online JSON-RPC resize fails VDI_IN_USE — INFRA-147). The
    reconciler refuses on a Running VM unless --halt is given, in which
    case it clean-shuts the VM, grows, and boots it again.
  * Logs before/after sizes, re-reads the VDI post-grow to verify.

The manifest is read from `nix eval --json <flake>#fleetManifest` (the
flake exposes fleetEval.compute for exactly this).
"""
from __future__ import annotations

import json
import subprocess
import time

from rich.console import Console

from .api import XoError, XoRest, XoRpc

console = Console()

GIB = 1024 ** 3


def load_manifest(flake_ref: str = ".") -> dict:
    """Evaluate the fleet compute manifest from the flake."""
    cmd = ["nix", "eval", "--json", f"{flake_ref}#fleetManifest"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise XoError(
            f"manifest eval failed ({' '.join(cmd)}):\n{result.stderr[-800:]}")
    return json.loads(result.stdout)


def _wait_power_state(rest: XoRest, name: str, want: str, timeout_s: int = 300) -> dict:
    deadline = time.time() + timeout_s
    vm = rest.vm_by_name(name)
    while vm.get("power_state") != want:
        if time.time() > deadline:
            raise XoError(f"{name}: still '{vm.get('power_state')}' after "
                          f"{timeout_s}s waiting for '{want}'")
        time.sleep(5)
        vm = rest.vm_by_name(name)
    return vm


def reconcile_host(host: str, manifest: dict, *, halt: bool = False,
                   dry_run: bool = False) -> bool:
    """Reconcile all declared disks of one host. Returns True if healthy
    (no action needed or all grows succeeded), False on refusal/failure."""
    entry = manifest.get(host)
    if entry is None:
        console.print(f"[red]{host}: not in fleet manifest[/red]")
        return False
    xoa = entry.get("xoa") or {}
    disks = xoa.get("disks") or []
    if not disks:
        console.print(f"[yellow]{host}: no xoa.disks declared — nothing to do[/yellow]")
        return True

    rest = XoRest()
    vm = rest.find_vm(host, extra_names=[entry.get("name", "")],
                      ip=entry.get("internal_ip") or None)
    vm_uuid = vm["uuid"]
    live = {d["name_label"]: d for d in rest.vm_disks(vm_uuid)}

    plan: list[tuple[dict, dict, int]] = []  # (declared, live_disk, target_bytes)
    ok = True
    for d in disks:
        name = d.get("name", "")
        base = int(d.get("size_gb") or 0)
        add = int(d.get("size_add_gb") or 0)
        target = (base + add) * GIB
        ld = live.get(name)
        if ld is None:
            console.print(f"[red]{host}:{name}: declared but no live VDI with "
                          f"that name_label[/red] (live: {list(live)})")
            ok = False
            continue
        actual = ld["size"]
        if actual == target:
            console.print(f"[green]{host}:{name}[/green] {actual / GIB:.0f}G — "
                          f"matches declaration (base {base}G + add {add}G). No-op.")
        elif actual > target:
            console.print(
                f"[yellow]{host}:{name} DRIFT[/yellow] live {actual / GIB:.1f}G > "
                f"declared {base}G+{add}G={base + add}G. NEVER shrinking — raise "
                f"size_add_gb to {int(actual / GIB) - base} to make the "
                f"declaration truthful.")
            ok = False
        else:
            console.print(
                f"[cyan]{host}:{name}[/cyan] live {actual / GIB:.1f}G < target "
                f"{base + add}G (base {base}G + add {add}G) — grow planned.")
            plan.append((d, ld, target))

    if not plan:
        return ok
    if dry_run:
        console.print(f"[dim]--dry-run: {len(plan)} grow(s) not executed.[/dim]")
        return ok

    # VDI resize needs the VM halted (INFRA-147).
    power = vm.get("power_state")
    started_halt = False
    if power not in ("Halted", "Running"):
        # Suspended / Paused / anything else: not a state we automate over.
        console.print(f"[red]{host}: unexpected power_state '{power}' — refusing.[/red]")
        return False
    if power == "Running":
        if not halt:
            console.print(
                f"[red]{host}: power_state={power} — VDI resize requires the VM "
                f"Halted. Re-run with --halt to shutdown→grow→boot, or halt it "
                f"yourself first.[/red]")
            return False
        console.print(f"{host}: clean shutdown (--halt)…")
        with XoRpc() as rpc:
            rpc.call("vm.stop", {"id": vm_uuid}, timeout=300)
        _wait_power_state(rest, host, "Halted")
        started_halt = True
        console.print(f"[green]{host}: Halted.[/green]")

    with XoRpc() as rpc:
        for d, ld, target in plan:
            name = d.get("name", "")
            before = ld["size"]
            console.print(f"{host}:{name}: vdi.set size "
                          f"{before / GIB:.1f}G → {target / GIB:.0f}G "
                          f"(vdi {ld['vdi_uuid']})…")
            rpc.call("vdi.set", {"id": ld["vdi_uuid"], "size": target}, timeout=300)
            after = rest.get(f"vdis/{ld['vdi_uuid']}", fields=["size"])
            after_size = int(after.get("size") or 0) if isinstance(after, dict) else 0
            if after_size >= target:
                console.print(f"[green]{host}:{name}: grown[/green] "
                              f"{before / GIB:.1f}G → {after_size / GIB:.1f}G (verified).")
            else:
                console.print(f"[red]{host}:{name}: vdi.set returned but size is "
                              f"{after_size / GIB:.1f}G (wanted {target / GIB:.0f}G)[/red]")
                ok = False

    if started_halt:
        console.print(f"{host}: booting…")
        with XoRpc() as rpc:
            rpc.call("vm.start", {"id": vm_uuid}, timeout=300)
        _wait_power_state(rest, host, "Running")
        console.print(f"[green]{host}: Running again.[/green]")
        console.print(f"[dim]{host}: in-guest partition/FS grow is the guest's "
                      f"job (PVE/PBS hosts run grow-storage on boot; NixOS "
                      f"images use their own grow path).[/dim]")

    return ok
