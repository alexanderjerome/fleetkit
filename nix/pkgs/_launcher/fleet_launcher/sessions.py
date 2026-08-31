"""fleet sessions — tmux-based session management for long-running fleet ops.

Any command that might run for more than ~30s (Colmena deploys, `tofu
apply`, fleet-wide NixOS rollouts) wraps itself in a detached tmux session
so the operator can:

  - Fire-and-forget dozens in parallel without blocking the terminal
  - Re-attach to watch progress at any time
  - Prevent accidental double-deploys of the same target

Session naming convention: ``fleet-<family>-<target>`` (e.g.
``fleet-deploy-netgate``, ``fleet-tf-apply-platform-bootstrap``). Prefix
``fleet-`` lets us find all fleet-owned sessions with a single glob.

Opt out via ``--no-session`` on any supporting command or the
``FLEET_NO_SESSION=1`` env var (for CI / scripts).
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import click
from rich.console import Console
from rich.table import Table

from ._util import env_get

console = Console()

# ── State persistence ────────────────────────────────────────────────
# A session's exit status survives only as long as the tmux pane stays
# alive (with our on-exit=keep behaviour the pane sticks until the user
# presses ENTER). For authoritative RUN/DONE-OK/DONE-FAIL post-teardown
# we write a small sentinel file when the wrapped command exits.

# User-global (XDG), NOT the project-root `.cache/fleet` that
# _util.fleet_cache_dir() manages — different scope, same rename.
_CACHE_HOME = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
_STATE_DIR = _CACHE_HOME / "fleet" / "sessions"
_LEGACY_STATE_DIR = _CACHE_HOME / "sk" / "sessions"


def _ensure_state_dir() -> None:
    # One-time silent migration of the pre-INFRA-218 location, mirroring
    # _util.fleet_cache_dir(). Sentinels for sessions still running under a
    # tmux command rendered by the old binary keep landing in the legacy
    # dir; _read_state() simply misses those and reports RUN/UNKNOWN from
    # liveness instead, which is the same degradation as a missing file.
    if not _STATE_DIR.exists() and _LEGACY_STATE_DIR.is_dir():
        try:
            _STATE_DIR.parent.mkdir(parents=True, exist_ok=True)
            os.rename(_LEGACY_STATE_DIR, _STATE_DIR)
        except OSError:
            pass  # cross-device / permissions — fall through, start fresh
    _STATE_DIR.mkdir(parents=True, exist_ok=True)


def _state_file(session: str) -> Path:
    return _STATE_DIR / f"{session}.status"


def _write_state(session: str, status: str, extra: dict | None = None) -> None:
    _ensure_state_dir()
    payload = {"status": status, "updated_at": time.time()}
    if extra:
        payload.update(extra)
    _state_file(session).write_text(json.dumps(payload))


def _read_state(session: str) -> dict | None:
    f = _state_file(session)
    if not f.exists():
        return None
    try:
        return json.loads(f.read_text())
    except Exception:
        return None


# ── tmux helpers ─────────────────────────────────────────────────────

def _tmux_available() -> bool:
    return shutil.which("tmux") is not None


def _session_exists(name: str) -> bool:
    result = subprocess.run(["tmux", "has-session", "-t", name],
                            capture_output=True, text=True)
    return result.returncode == 0


def _session_alive(name: str) -> bool:
    """Pane running a real process (not the dead-pane post-exit hold)."""
    result = subprocess.run(
        ["tmux", "list-panes", "-t", name, "-F", "#{pane_dead}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return False
    return "0" in result.stdout


def _pane_capture(name: str, lines: int = 100) -> str:
    result = subprocess.run(
        ["tmux", "capture-pane", "-t", name, "-p", "-S", f"-{lines}"],
        capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else ""


# ── Core wrapping primitive ──────────────────────────────────────────

def running_inside(session_name: str) -> bool:
    return env_get("FLEET_SESSION_NAME") == session_name


def dispatch_session(
    session_name: str,
    cmd: list[str],
    *,
    cwd: Path | None = None,
    description: str | None = None,
    env: dict | None = None,
) -> int:
    """Launch ``cmd`` inside a new detached tmux session.

    - If called from INSIDE the target session (``FLEET_SESSION_NAME`` set),
      returns -1 so the caller can fall through to its inline path.
    - If the named session already exists and is alive, refuses with
      instructions to attach or kill.
    - Otherwise creates a detached session, runs the command, writes a
      sentinel state file on exit, and holds the pane until ENTER.

    Returns 0 on successful dispatch, non-zero on refusal / error.
    """
    if env_get("FLEET_NO_SESSION") == "1":
        return -1
    if running_inside(session_name):
        return -1
    if not _tmux_available():
        console.print("[yellow]tmux not found — running inline.[/yellow]")
        return -1

    if _session_exists(session_name):
        if _session_alive(session_name):
            console.print(
                f"[red]ERROR:[/red] session [bold]{session_name}[/bold] is already running.\n"
                f"  attach:  tmux attach -t {session_name}\n"
                f"  kill:    fleet sessions kill {session_name}"
            )
            return 2
        # Dead pane — clean up before relaunching.
        subprocess.run(["tmux", "kill-session", "-t", session_name],
                       capture_output=True)

    # Build the shell command that runs inside the tmux pane.
    # We set FLEET_SESSION_NAME so the inner `fleet` invocation knows not to
    # re-wrap itself, capture the exit code, write a sentinel, and hold
    # the pane open for scrollback.
    env_parts = [f"FLEET_SESSION_NAME={shlex.quote(session_name)}"]
    if env:
        for k, v in env.items():
            env_parts.append(f"{k}={shlex.quote(str(v))}")
    cmd_str = " ".join(shlex.quote(c) for c in cmd)

    sentinel_cmd = (
        f"_fleet_write_status() {{ "
        f"  mkdir -p {shlex.quote(str(_STATE_DIR))}; "
        f"  printf '%s\\n' \"{{\\\"status\\\":\\\"$1\\\",\\\"updated_at\\\":$(date +%s),\\\"exit_code\\\":$2}}\" "
        f"  > {shlex.quote(str(_state_file(session_name)))}; "
        f"}}"
    )
    wrapped = (
        f"{sentinel_cmd}; "
        f"_fleet_write_status RUN 0; "
        f"env {' '.join(env_parts)} {cmd_str}; "
        f"_rc=$?; "
        f"if [ $_rc -eq 0 ]; then _fleet_write_status DONE-OK $_rc; "
        f"else _fleet_write_status DONE-FAIL $_rc; fi; "
        f"echo; echo '=== {session_name} exited (rc=' $_rc ') — press ENTER to close ==='; "
        f"read"
    )

    new_session_cmd = ["tmux", "new-session", "-d", "-s", session_name]
    if cwd:
        new_session_cmd += ["-c", str(cwd)]
    new_session_cmd += [wrapped]

    subprocess.run(new_session_cmd, check=True)
    _write_state(session_name, "RUN", {"description": description or " ".join(cmd), "exit_code": None})

    # Early-death watch (INFRA-171): a session whose command dies within the
    # first few seconds is almost always an environment failure (rc=127
    # "command not found", bad cwd, …) — previously this reported "launched"
    # and exited 0 while the deploy never ran. Poll briefly and surface it.
    deadline = time.time() + 4.0
    while time.time() < deadline:
        time.sleep(0.25)
        state = _read_state(session_name) or {}
        status = state.get("status")
        if status == "DONE-OK":
            break  # legitimately finished fast
        if status == "DONE-FAIL":
            exit_code = state.get("exit_code")
            rc = int(exit_code) if str(exit_code).isdigit() else 1
            console.print(
                f"[red]ERROR:[/red] session [bold]{session_name}[/bold] died "
                f"immediately (rc={rc}). Last output:"
            )
            for line in _pane_capture(session_name, 25).splitlines()[-15:]:
                if line.strip():
                    console.print(f"  [dim]{line}[/dim]")
            subprocess.run(["tmux", "kill-session", "-t", session_name],
                           capture_output=True)
            return rc or 1
        if not _session_exists(session_name):
            console.print(
                f"[red]ERROR:[/red] session [bold]{session_name}[/bold] "
                f"vanished right after launch."
            )
            return 1

    console.print(
        f"[green]launched[/green] {session_name}  "
        f"[dim](attach: tmux attach -t {session_name} · "
        f"status: fleet sessions status · kill: fleet sessions kill {session_name})[/dim]"
    )
    return 0


# ── Public CLI (fleet sessions …) ───────────────────────────────────────

@dataclass
class _SessionInfo:
    name: str
    alive: bool
    last_line: str
    state: str  # RUN | DONE-OK | DONE-FAIL | UNKNOWN
    exit_code: int | None


# New sessions are only ever created with SESSION_PREFIX. LEGACY_PREFIX is
# matched on *discovery* so `fleet sessions list/kill` can still see and reap
# sk-* sessions that a pre-INFRA-218 build left running. Drop it with the
# _util env shim (2026-12-01) — by then no such session can still exist.
SESSION_PREFIX = "fleet-"
LEGACY_SESSION_PREFIX = "sk-"


def _matches_prefix(name: str, prefix: str) -> bool:
    if name.startswith(prefix):
        return True
    return prefix == SESSION_PREFIX and name.startswith(LEGACY_SESSION_PREFIX)


def _collect_sessions(prefix: str = SESSION_PREFIX) -> list[_SessionInfo]:
    result = subprocess.run(["tmux", "ls"], capture_output=True, text=True)
    if result.returncode != 0:
        return []
    infos: list[_SessionInfo] = []
    for line in result.stdout.splitlines():
        name = line.split(":", 1)[0]
        if not _matches_prefix(name, prefix):
            continue
        alive = _session_alive(name)
        dump = _pane_capture(name, 30)
        # Last non-blank / non-sentinel line.
        last = ""
        for raw in reversed(dump.splitlines()):
            s = raw.strip()
            if not s or s.startswith("==="):
                continue
            last = s[:120]
            break
        sentinel = _read_state(name)
        if sentinel:
            state = sentinel.get("status", "UNKNOWN")
            exit_code = sentinel.get("exit_code")
        else:
            state = "RUN" if alive else "UNKNOWN"
            exit_code = None
        infos.append(_SessionInfo(name, alive, last, state, exit_code))
    return infos


@click.group("sessions")
def sessions_cli() -> None:
    """Manage fleet-owned tmux sessions."""


@sessions_cli.command("list")
@click.option("--prefix", default=SESSION_PREFIX, help="Session name prefix filter.")
def sessions_list(prefix: str) -> None:
    """One-row-per-session overview (state, last line)."""
    infos = _collect_sessions(prefix)
    if not infos:
        console.print(f"No '{prefix}*' sessions.")
        return
    t = Table()
    t.add_column("State", style="bold")
    t.add_column("Name", style="cyan")
    t.add_column("Last output", style="dim")
    for i in sorted(infos, key=lambda x: x.name):
        style = {"RUN": "yellow", "DONE-OK": "green", "DONE-FAIL": "red"}.get(i.state, "white")
        t.add_row(f"[{style}]{i.state}[/{style}]", i.name, i.last_line)
    console.print(t)


@sessions_cli.command("attach")
@click.argument("name")
def sessions_attach(name: str) -> None:
    """tmux attach -t NAME."""
    if not _session_exists(name):
        console.print(f"[red]ERROR:[/red] no session named {name}")
        sys.exit(1)
    os.execvp("tmux", ["tmux", "attach", "-t", name])


@sessions_cli.command("kill")
@click.argument("name")
def sessions_kill(name: str) -> None:
    """Kill a specific session, or 'all' for every fleet-* session."""
    if name == "all":
        for info in _collect_sessions(SESSION_PREFIX):
            subprocess.run(["tmux", "kill-session", "-t", info.name])
            console.print(f"killed {info.name}")
        return
    if not _session_exists(name):
        console.print(f"[yellow]no session {name}[/yellow]")
        return
    subprocess.run(["tmux", "kill-session", "-t", name])
    console.print(f"killed {name}")


@sessions_cli.command("status")
@click.option("--prefix", default=SESSION_PREFIX)
def sessions_status(prefix: str) -> None:
    """Alias of list — match scripts/tmux-deploy.sh UX."""
    ctx = click.get_current_context()
    ctx.invoke(sessions_list, prefix=prefix)
