"""fleet utilities — Miscellaneous build and schema tools."""
from __future__ import annotations

import json
import subprocess
import sys

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir, run_shell

console = Console()


@click.group("utilities")
def utilities():
    """Miscellaneous build and inspection tools.

    One-off helpers for Nix binary cache management and CLI-surface
    dumps.
    """


@utilities.command("builder-cache-key")
def builder_cache_key():
    """Fetch the Nix binary cache public key from the builder host.

    SSHs into the builder container, reads the cache signing key,
    and writes it to ``nix/secrets/secrets/keys/builder-cache-pub-key.pem``.
    """
    root = find_project_root()
    hosts_file = fleet_cache_dir(root) / "hosts.json"

    if not hosts_file.exists():
        console.print("[red]ERROR:[/red] .cache/fleet/hosts.json not found")
        sys.exit(1)

    with open(hosts_file) as f:
        hosts = json.load(f)

    builder = hosts.get("builder", {})
    ip = builder.get("ip", "")
    if not ip:
        console.print("[red]ERROR:[/red] No builder IP in hosts.json")
        sys.exit(1)

    console.print(f"Fetching cache public key from builder ({ip})...")
    out_path = root / "nix" / "secrets" / "secrets" / "keys" / "builder-cache-pub-key.pem"

    result = subprocess.run(
        [
            "ssh",
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            f"root@{ip}",
            "cat", "/data/nix/cache-pub-key.pem",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        console.print(f"[red]ERROR:[/red] {result.stderr.strip()}")
        sys.exit(1)

    out_path.write_text(result.stdout)
    console.print(f"Wrote {out_path}:")
    console.print(result.stdout.strip())


@utilities.command("dump-cli")
@click.option("--output", "-o", default=None,
              help="Write to file instead of stdout.")
def dump_cli(output: str | None):
    """Dump the full CLI command tree with all help text, options, and arguments.

    Walks the entire Click command hierarchy and prints every command
    path, its docstring, arguments, and options. Useful for auditing
    the CLI surface for redundant or broken commands.
    """
    from .main import fleet as root_cli

    lines: list[str] = []

    def _dump(cmd: click.BaseCommand, prefix: str) -> None:
        path = f"{prefix} {cmd.name}" if cmd.name else prefix
        lines.append("=" * 70)
        lines.append(f"COMMAND: {path}")
        lines.append("=" * 70)

        # Help text
        help_text = cmd.get_short_help_str(limit=300)
        lines.append(f"  Summary: {help_text}")
        if isinstance(cmd, click.Command) and cmd.help:
            for line in cmd.help.strip().splitlines():
                lines.append(f"  {line}")

        # Arguments
        args = [p for p in cmd.params if isinstance(p, click.Argument)]
        if args:
            lines.append("")
            lines.append("  Arguments:")
            for arg in args:
                required = "required" if arg.required else "optional"
                nargs = arg.nargs
                type_name = arg.type.name if hasattr(arg.type, "name") else str(arg.type)
                detail = f"type={type_name}, {required}, nargs={nargs}"
                lines.append(f"    {arg.human_readable_name:20s}  {detail}")

        # Options
        opts = [p for p in cmd.params if isinstance(p, click.Option)]
        if opts:
            lines.append("")
            lines.append("  Options:")
            for opt in opts:
                decls = ", ".join(opt.opts)
                help_str = opt.help or ""
                default = opt.default
                if opt.is_flag:
                    detail = f"flag, default={default}"
                else:
                    type_name = opt.type.name if hasattr(opt.type, "name") else str(opt.type)
                    detail = f"type={type_name}, default={default!r}"
                lines.append(f"    {decls:30s}  {detail}")
                if help_str:
                    lines.append(f"    {'':30s}  {help_str}")

        lines.append("")

        # Recurse into subcommands
        if isinstance(cmd, click.MultiCommand):
            for name in cmd.list_commands(click.Context(cmd)):
                sub = cmd.get_command(click.Context(cmd), name)
                if sub:
                    _dump(sub, path)

    _dump(root_cli, "")

    text = "\n".join(lines)

    if output:
        from pathlib import Path
        Path(output).write_text(text)
        console.print(f"[green]Wrote CLI dump to {output}[/green]")
    else:
        click.echo(text)
