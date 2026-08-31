"""Shared utilities for fleet launcher modules."""
from __future__ import annotations

import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path


# ── Environment variables (INFRA-218) ────────────────────────────────
# Framework env vars are FLEET_*. Before the extraction they carried the
# originating company's initials (SK_*); those names are still ACCEPTED as
# a deprecated fallback, because the failure mode of a hard rename is
# silent: an operator shell or CI job exporting SK_NO_SESSION=1 would keep
# running and quietly start spawning tmux sessions again.
#
#   ┌──────────────────────────────────────────────────────────────┐
#   │ TEMPORARY COMPATIBILITY SHIM — DELETE AFTER 2026-12-01.       │
#   │ Remove _LEGACY_ENV_* and inline os.environ.get() at the read  │
#   │ sites; nothing in the framework ever *writes* an SK_* name.   │
#   └──────────────────────────────────────────────────────────────┘
_LEGACY_ENV_PREFIX = "SK_"
_LEGACY_ENV_SUNSET = "2026-12-01"
_legacy_env_warned: set[str] = set()


def env_get(name: str, default: str | None = None) -> str | None:
    """Read a ``FLEET_*`` env var, falling back to the deprecated ``SK_*`` name.

    The fallback warns once per variable per process and disappears on the
    sunset date above. Always pass the *new* name; the legacy name is
    derived from it.
    """
    val = os.environ.get(name)
    if val is not None:
        return val
    legacy = _LEGACY_ENV_PREFIX + name.removeprefix("FLEET_")
    val = os.environ.get(legacy)
    if val is None:
        return default
    if legacy not in _legacy_env_warned:
        _legacy_env_warned.add(legacy)
        sys.stderr.write(
            f"fleet: DEPRECATED env var {legacy} is set — rename it to {name}. "
            f"The {legacy} fallback is removed after {_LEGACY_ENV_SUNSET}.\n"
        )
    return val


# Strips ANSI escape sequences (color, cursor movement, etc.) — used to
# produce a human-readable `.clean.log` sibling for logs captured by script(1).
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _write_clean_log(raw_log: Path) -> Path | None:
    """Produce a sibling `<name>.clean.log` with ANSI escapes stripped.

    Returns the clean path on success, None on failure.
    """
    try:
        raw = raw_log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    clean = _strip_ansi(raw)
    clean_path = raw_log.with_suffix(".clean.log")
    try:
        clean_path.write_text(clean, encoding="utf-8")
        return clean_path
    except OSError:
        return None


# Signal words that mark "something went wrong" in deploy/build output.
# Case-insensitive. Extended via FLEET_ERROR_PATTERN env var (regex, overrides).
# "command not found" / COMMAND_EXIT_CODE cover the rc=127 "colmena not on
# PATH" class that previously produced an empty errors log (INFRA-171).
_DEFAULT_ERROR_PATTERN = (
    r"ERROR|failed|Failed|FAILED|exited|error:|Error:|Traceback|Exception|fatal"
    r"|command not found|COMMAND_EXIT_CODE=\"[1-9]"
)


def _error_pattern() -> re.Pattern[str]:
    user_pat = env_get("FLEET_ERROR_PATTERN")
    return re.compile(user_pat or _DEFAULT_ERROR_PATTERN, re.IGNORECASE if not user_pat else 0)


def _write_errors_log(clean_log: Path) -> tuple[Path, bool] | None:
    """Produce a sibling `<name>.errors.log` starting at the first error line.

    Captures from the first match of ``FLEET_ERROR_PATTERN`` (or the default
    pattern covering ERROR/failed/exited/Traceback/etc.) through end of file.
    On a clean run the file contains a single line marking no errors detected.

    Returns (path, had_errors) on success, None on read/write failure.
    """
    try:
        text = clean_log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    lines = text.splitlines()
    pat = _error_pattern()
    first_idx: int | None = None
    for i, line in enumerate(lines):
        if pat.search(line):
            first_idx = i
            break
    errors_path = clean_log.with_suffix(".errors.log")
    try:
        if first_idx is None:
            errors_path.write_text("(no errors detected)\n", encoding="utf-8")
            return errors_path, False
        errors_path.write_text("\n".join(lines[first_idx:]) + "\n", encoding="utf-8")
        return errors_path, True
    except OSError:
        return None


def sk_executable() -> str:
    """Absolute path to the currently-running `fleet` entry point.

    Used when fleet needs to re-invoke itself (tmux sessions, `nix develop`
    re-exec) — a bare binary name on PATH is not reliable in
    non-interactive contexts (tmux server env, CI, devshell-without-venv).
    """
    exe = sys.argv[0]
    if not os.path.isfile(exe):
        found = shutil.which(exe) or shutil.which("fleet")
        if found:
            exe = found
    return os.path.abspath(exe)


def find_project_root() -> Path:
    """Locate the consumer repo root.

    Tries git rev-parse first, then walks up looking for flake.nix.
    """
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return Path(root)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    p = Path.cwd()
    for _ in range(10):
        if (p / "flake.nix").exists():
            return p
        p = p.parent

    return Path.cwd()


def fleet_cache_dir(root: Path | None = None) -> Path:
    """Return the launcher cache directory ``<root>/.cache/fleet``.

    Single choke point for the on-disk cache location (hosts.json,
    hosts-backups/, the generated ansible inventory). *root* defaults to
    :func:`find_project_root`.

    One-time silent migration: if ``.cache/fleet`` does not exist yet but
    the pre-rename ``sk`` cache directory does, the old directory is
    renamed in place so cached state carries over. The directory is created when
    missing, so callers can write into it directly.
    """
    if root is None:
        root = find_project_root()
    cache = root / ".cache"
    new = cache / "fleet"
    if not new.exists():
        old = cache / "sk"
        if old.is_dir():
            try:
                os.rename(old, new)
            except OSError:
                pass  # cross-device / permission oddity — fall through, start fresh
    new.mkdir(parents=True, exist_ok=True)
    return new


def _tee_stream(src: io.RawIOBase, dest: io.IOBase, buf: list[bytes]) -> None:
    """Read from src, write to dest (live), and collect into buf."""
    while True:
        chunk = src.read(4096)
        if not chunk:
            break
        dest.buffer.write(chunk)
        dest.buffer.flush()
        buf.append(chunk)


def _log_dir() -> Path:
    root = find_project_root()
    d = root / ".logs"
    d.mkdir(exist_ok=True)
    return d


def _write_failure_log(cmd: list[str], returncode: int,
                       stdout_bytes: bytes, stderr_bytes: bytes) -> Path:
    """Write full command output to a timestamped log file. Return the path."""
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    cmd_slug = cmd[0].rsplit("/", 1)[-1] if cmd else "unknown"
    log_path = _log_dir() / f"{cmd_slug}-{ts}.log"

    with open(log_path, "w") as f:
        f.write(f"Command: {' '.join(cmd)}\n")
        f.write(f"Exit code: {returncode}\n")
        f.write(f"Timestamp: {datetime.now().isoformat()}\n")
        f.write("=" * 72 + "\n\n")
        if stdout_bytes:
            f.write("── stdout ──\n")
            f.write(stdout_bytes.decode("utf-8", errors="replace"))
            f.write("\n")
        if stderr_bytes:
            f.write("── stderr ──\n")
            f.write(stderr_bytes.decode("utf-8", errors="replace"))
            f.write("\n")

    return log_path


def _extract_error_summary(output: str, max_lines: int = 20) -> str:
    """Pull the most useful error lines from tofu/Colmena output."""
    lines = output.splitlines()
    error_lines: list[str] = []

    # Collect lines containing error indicators
    markers = ("error:", "Error:", "ERROR", "failed", "Failed", "FAILED",
               "Traceback", "Exception", "diagnostics:")
    in_diagnostics = False

    for line in lines:
        if any(m in line for m in markers):
            in_diagnostics = True
        if in_diagnostics:
            error_lines.append(line)
        # Stop collecting after a blank line following diagnostics
        if in_diagnostics and not line.strip() and len(error_lines) > 3:
            in_diagnostics = False

    if error_lines:
        return "\n".join(error_lines[:max_lines])

    # Fallback: last N lines
    return "\n".join(lines[-max_lines:])


def _make_log_path(cmd: list[str], log_label: str | None) -> Path:
    """Compose a timestamped log path for a command invocation."""
    label = log_label or (cmd[0].rsplit("/", 1)[-1] if cmd else "command")
    # Strip unsafe chars from label
    label = "".join(c if c.isalnum() or c in "-_" else "-" for c in label)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    return _log_dir() / f"{label}-{ts}.log"


def run_shell(
    cmd: list[str],
    *,
    cwd: Path | str | None = None,
    check: bool = False,
    exit_on_fail: bool = True,
    interactive: bool = False,
    log_label: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a shell command, streaming output live.

    When *interactive* is True the child inherits stdin/stdout/stderr
    directly, giving it full TTY access (colors, prompts, ctrl-c, etc.).

    By default, interactive runs are captured to a timestamped file under
    ``.logs/`` via ``script(1)``; the path is printed at the end (on
    success, failure, or ^C). ``RUST_BACKTRACE=1`` is set by default so
    Rust-based tools (colmena) emit backtraces on panic.

    Environment opt-outs:
      FLEET_NO_LOG=1        disable log-to-file capture
      FLEET_NO_BACKTRACE=1  don't set RUST_BACKTRACE=1

    ``log_label`` overrides the log filename prefix (default: cmd[0]).

    On failure, writes full output to .logs/ and prints a concise summary
    (non-interactive path) or the live log path (interactive path).
    """
    if cwd is None:
        cwd = find_project_root()

    # Propagate a Rust backtrace by default so colmena panics are diagnosable
    env = os.environ.copy()
    if env_get("FLEET_NO_BACKTRACE") != "1":
        env.setdefault("RUST_BACKTRACE", "1")

    log_enabled = env_get("FLEET_NO_LOG") != "1"

    if interactive:
        log_path: Path | None = None
        rc_file: Path | None = None
        if log_enabled and shutil.which("script"):
            log_path = _make_log_path(cmd, log_label)
            rc_file = log_path.with_suffix(".rc")
            quoted = " ".join(shlex.quote(a) for a in cmd)
            # script -q  (no banner) -f (flush) -e (propagate child exit code).
            # Belt-and-braces (INFRA-171): also write the wrapped command's rc
            # to a sentinel file ourselves — `script -e` has been observed to
            # report 0 while the typescript footer said COMMAND_EXIT_CODE=127,
            # silently turning failed deploys into successes. The sentinel is
            # authoritative when it disagrees with script's own exit status.
            inner = (
                f"{quoted}; _sk_rc=$?; "
                f"printf '%s' \"$_sk_rc\" > {shlex.quote(str(rc_file))}; "
                f"exit $_sk_rc"
            )
            wrapped = ["script", "-q", "-f", "-e", str(log_path), "-c", inner]
        else:
            wrapped = cmd

        def _emit_log_paths(prefix: str, *, rc: int | None = None) -> None:
            """Print raw + clean + errors log locations. Idempotent.

            If rc indicates failure and the errors log has content, also echo
            the first chunk of that content inline so the user doesn't have to
            open the file for a quick diagnosis.
            """
            if not log_path:
                return
            clean = _write_clean_log(log_path)
            sys.stderr.write(f"{prefix} {log_path}\n")
            if clean:
                sys.stderr.write(f"{prefix.replace('[log]', '[clean]')} {clean}\n")
                err_result = _write_errors_log(clean)
                if err_result:
                    errors_path, had_errors = err_result
                    sys.stderr.write(
                        f"{prefix.replace('[log]', '[errors]')} {errors_path}"
                        f"{'' if had_errors else ' (empty)'}\n"
                    )
                    # On failure, echo a slice of the errors log so the user
                    # sees the diagnostic immediately without opening the file.
                    if rc is not None and rc != 0 and had_errors:
                        try:
                            content = errors_path.read_text(encoding="utf-8", errors="replace")
                        except OSError:
                            content = ""
                        lines = content.splitlines()
                        max_echo = int(env_get("FLEET_ERROR_ECHO_LINES", "60"))
                        sys.stderr.write("\n─── error context (first "
                                         f"{min(len(lines), max_echo)} lines "
                                         f"from {errors_path.name}) ───\n")
                        for line in lines[:max_echo]:
                            sys.stderr.write(f"  {line}\n")
                        if len(lines) > max_echo:
                            sys.stderr.write(f"  … {len(lines) - max_echo} more lines in {errors_path}\n")
                        sys.stderr.write("─" * 60 + "\n")

        try:
            rc = subprocess.call(wrapped, cwd=cwd, env=env)
        except KeyboardInterrupt:
            sys.stderr.write("\n^C interrupted.\n")
            if log_path:
                _emit_log_paths("  [partial log]", rc=130)
            raise

        # Reconcile with the rc sentinel: any non-zero wins (INFRA-171).
        if rc_file is not None:
            try:
                sentinel_rc = int(rc_file.read_text().strip())
            except (OSError, ValueError):
                sentinel_rc = None
            else:
                if rc == 0 and sentinel_rc != 0:
                    sys.stderr.write(
                        f"\n[sk] wrapped command exited {sentinel_rc} but "
                        f"script(1) reported 0 — propagating {sentinel_rc}.\n")
                    rc = sentinel_rc
            try:
                rc_file.unlink(missing_ok=True)
            except OSError:
                pass

        result = subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")

        if rc == 0:
            sys.stderr.write("\n")
            _emit_log_paths("[log]", rc=0)
        else:
            sys.stderr.write(f"\n{'─' * 60}\n")
            sys.stderr.write(f"✗ Command failed (exit {rc})\n")
            _emit_log_paths("  [full log]", rc=rc)
            sys.stderr.write(f"{'─' * 60}\n\n")
            if exit_on_fail:
                sys.exit(rc)
        return result

    proc = subprocess.Popen(
        cmd, cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    stdout_buf: list[bytes] = []
    stderr_buf: list[bytes] = []

    t_out = threading.Thread(target=_tee_stream,
                             args=(proc.stdout, sys.stdout, stdout_buf))
    t_err = threading.Thread(target=_tee_stream,
                             args=(proc.stderr, sys.stderr, stderr_buf))
    t_out.start()
    t_err.start()
    t_out.join()
    t_err.join()

    proc.wait()

    stdout_bytes = b"".join(stdout_buf)
    stderr_bytes = b"".join(stderr_buf)

    result = subprocess.CompletedProcess(
        cmd, proc.returncode,
        stdout=stdout_bytes.decode("utf-8", errors="replace"),
        stderr=stderr_bytes.decode("utf-8", errors="replace"),
    )

    if result.returncode != 0:
        full_output = result.stdout + result.stderr
        log_path = _write_failure_log(cmd, result.returncode,
                                      stdout_bytes, stderr_bytes)
        summary = _extract_error_summary(full_output)

        sys.stderr.write(f"\n{'─' * 60}\n")
        sys.stderr.write(f"✗ Command failed (exit {result.returncode})\n")
        sys.stderr.write(f"  Full log: {log_path}\n")
        sys.stderr.write(f"{'─' * 60}\n")
        if summary:
            sys.stderr.write(summary + "\n")
        sys.stderr.write(f"{'─' * 60}\n\n")

        if exit_on_fail:
            sys.exit(result.returncode)

    return result
