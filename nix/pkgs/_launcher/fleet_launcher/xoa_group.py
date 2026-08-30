"""`fleet xoa` — thin shim over the standalone xoa-cli package (INFRA-172).

The XOA operator commands were split out of the launcher into
nix/pkgs/xoa-cli (flake package `xoa-cli`) so nix config / fleet tooling /
the INFRA-166 MCP endpoint can call them without the whole fleet CLI.

Preferred path: `xoa_cli` is installed in the venv (uv source in the root
pyproject.toml) and its click group is re-exported here unchanged, so every
`fleet xoa <cmd>` keeps working. Fallback: if the import is unavailable (stale
venv), forward the invocation to `nix run .#xoa-cli --`.

Command surface (see xoa_cli.main): list-srs, list-networks,
list-templates, list-isos, sr-scan, vm-info, vm-halt, vm-start,
vm-snapshot, vm-set-memory, resize-disk, reconcile-disks.

NOTE: `resize-disk` semantics changed vs the legacy in-launcher version —
mutations now go over the XO JSON-RPC websocket (`vdi.set`) because the
REST PATCH size was a silent no-op (INFRA-147), and the VM must be Halted
(--halt automates shutdown→grow→boot). The old online-REST resize never
actually grew anything.
"""
from __future__ import annotations

try:
    from xoa_cli.main import xoa  # noqa: F401  (re-exported click group)
except ImportError:  # stale venv — forward to the nix package
    import os

    import click

    from ._util import find_project_root

    @click.command(
        "xoa",
        context_settings={
            "ignore_unknown_options": True,
            "help_option_names": [],
        },
    )
    @click.argument("args", nargs=-1, type=click.UNPROCESSED)
    def xoa(args: tuple[str, ...]) -> None:  # type: ignore[misc]
        """XCP-ng / XOA operator commands (forwarded to `nix run .#xoa-cli`)."""
        os.chdir(find_project_root())
        os.execvp("nix", ["nix", "run", ".#xoa-cli", "--", *args])
