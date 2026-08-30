"""PVE/PBS auto-install answer-file HTTP server.

Stdlib-only. Reads a JSON config at startup with a list of {mac,
name, answer} entries, listens for POST /answer, substring-matches
the POSTed system_info JSON against each MAC, returns the first
match's answer.toml as text/plain.

Wire protocol (PVE installer side, https://pve.proxmox.com/wiki/Automated_Installation):
  - Installer prepared with `proxmox-auto-install-assistant prepare-iso
    --fetch-from http --url <this-server>/answer`.
  - At install time, installer POSTs JSON describing the host
    (network interfaces, dmi, disks, etc.) to /answer.
  - Server returns answer.toml as response body. Plaintext content
    type; installer feeds it directly into its parser.

Match strategy is intentionally dumb: the installer's POST body is
JSON-encoded system_info, and the MAC appears in there in lowercase
hex. We lowercase both sides and do a substring search — same shape
the upstream natankeddem/autopve reference uses. Avoids tying to a
specific system_info schema version.
"""
from __future__ import annotations

import json
import os
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if len(sys.argv) != 2:
    print("usage: server.py <config.json>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    CONFIG = json.load(f)

BIND_ADDRESS = CONFIG.get("bind_address", "127.0.0.1")
PORT = int(CONFIG["port"])
HOSTS = CONFIG["hosts"]


def find_answer(body_str: str) -> tuple[str | None, str | None]:
    """Return (host name, answer toml) for the first matching MAC, else (None, None)."""
    lower = body_str.lower()
    for entry in HOSTS:
        if entry["mac"].lower() in lower:
            return entry["name"], entry["answer"]
    return None, None


class Handler(BaseHTTPRequestHandler):
    # systemd journal already timestamps; suppress BaseHTTPRequestHandler's
    # double-prefix.
    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.address_string()} - {fmt % args}\n")

    def do_GET(self):
        # GET /health — liveness probe.
        if self.path == "/health":
            self._respond(HTTPStatus.OK, "ok\n", "text/plain")
            return

        # GET /first-boot/<hostname> — per-host post-install bootstrap
        # script. PVE's [first-boot] machinery downloads the body,
        # chmods 0700, executes once as root, then deletes it.
        # Returns 404 when:
        #   - hostname doesn't exist in config
        #   - host has no first_boot_script declared (empty string)
        if self.path.startswith("/first-boot/"):
            name = self.path[len("/first-boot/"):]
            for entry in HOSTS:
                if entry.get("hostname") == name:
                    script = entry.get("first_boot_script", "")
                    if not script:
                        sys.stderr.write(f"no first-boot script for '{name}'\n")
                        self._respond(HTTPStatus.NOT_FOUND, "no first-boot script\n", "text/plain")
                        return
                    sys.stderr.write(f"serving first-boot script for '{name}' to {self.client_address[0]}\n")
                    self._respond(HTTPStatus.OK, script, "text/x-shellscript")
                    return
            sys.stderr.write(f"unknown host '{name}' in first-boot fetch from {self.client_address[0]}\n")
            self._respond(HTTPStatus.NOT_FOUND, "unknown host\n", "text/plain")
            return

        self._respond(HTTPStatus.NOT_FOUND, "use POST /answer or GET /first-boot/<host>\n", "text/plain")

    def do_POST(self):
        if self.path != "/answer":
            self._respond(HTTPStatus.NOT_FOUND, "POST /answer only\n", "text/plain")
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._respond(HTTPStatus.BAD_REQUEST, "bad Content-Length\n", "text/plain")
            return

        if length <= 0 or length > 1_000_000:  # 1 MB sanity cap on system_info
            self._respond(HTTPStatus.BAD_REQUEST, "missing or oversized body\n", "text/plain")
            return

        body = self.rfile.read(length)
        try:
            body_str = body.decode("utf-8")
        except UnicodeDecodeError:
            self._respond(HTTPStatus.BAD_REQUEST, "body must be UTF-8\n", "text/plain")
            return

        name, answer = find_answer(body_str)
        if answer is None:
            sys.stderr.write(f"no match for POST from {self.client_address[0]}\n")
            self._respond(HTTPStatus.NOT_FOUND, "no answer for this host\n", "text/plain")
            return

        sys.stderr.write(f"serving '{name}' to {self.client_address[0]}\n")
        self._respond(HTTPStatus.OK, answer, "text/plain")

    def _respond(self, status, body, content_type):
        body_bytes = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


if __name__ == "__main__":
    server = ThreadingHTTPServer((BIND_ADDRESS, PORT), Handler)
    sys.stderr.write(
        f"pve-installer-answers listening on {BIND_ADDRESS}:{PORT}, "
        f"{len(HOSTS)} host(s) configured\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
