"""Xen Orchestra API clients — REST (reads) + JSON-RPC websocket (mutations).

Two surfaces, on purpose:

* **REST** (`/rest/v0/…`, token cookie) — all read paths. Same surface the
  fleet launcher's `xoa_api.py` and the xo-grafana-exporter use.
* **JSON-RPC over websocket** (`wss://…/api/`) — all mutations. The REST
  PATCH surface is unreliable for writes on our XOA edition (INFRA-147:
  `PATCH /vdis/<uuid> {"size": …}` is a silent no-op), while the JSON-RPC
  `vdi.set` / `vm.set` / `vm.stop` / `vm.start` methods are the same ones
  upstream `xo-cli` drives and are known-good.

Credentials resolve in order:
  1. env — XOA_URL (https://…), XOA_TOKEN, XOA_INSECURE
  2. SOPS — `integrations.xen-orchestra` from <repo>/nix/secrets/secrets.yaml
     (url is stored wss://… for the Terraform provider; converted here).
"""
from __future__ import annotations

import json
import os
import ssl
import subprocess
import urllib.error
import urllib.request
from pathlib import Path


class XoError(RuntimeError):
    """Any XO API failure (transport or application-level)."""


# ── Credentials ──────────────────────────────────────────────────────


def _find_repo_root() -> Path | None:
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True, stderr=subprocess.DEVNULL).strip()
        return Path(root)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _ws_to_http(url: str) -> str:
    if url.startswith("wss://"):
        return "https://" + url[len("wss://"):]
    if url.startswith("ws://"):
        return "http://" + url[len("ws://"):]
    return url


def load_credentials() -> tuple[str, str, bool]:
    """Return (https_url, token, insecure). Raises XoError when unresolvable."""
    url = os.environ.get("XOA_URL", "")
    token = os.environ.get("XOA_TOKEN", "")
    insecure = os.environ.get("XOA_INSECURE", "true").lower() in ("true", "1", "yes")
    if url and token:
        return _ws_to_http(url).rstrip("/"), token, insecure

    # SOPS fallback — mirrors fleet_launcher.main._setup_env.
    secrets = os.environ.get("XOA_SOPS_FILE", "")
    if not secrets:
        root = _find_repo_root()
        if root:
            secrets = str(root / "nix/secrets/secrets.yaml")
    if secrets and Path(secrets).exists():
        env = os.environ.copy()
        if not env.get("SOPS_AGE_KEY") and not env.get("SOPS_AGE_KEY_FILE"):
            key_file = os.path.expanduser("~/.ssh/sops-age.key")
            if os.path.isfile(key_file):
                env["SOPS_AGE_KEY_FILE"] = key_file
        try:
            out = subprocess.run(
                ["sops", "-d", "--extract", '["integrations"]["xen-orchestra"]', secrets],
                capture_output=True, text=True, timeout=15, env=env)
            if out.returncode == 0:
                import yaml
                xo = yaml.safe_load(out.stdout) or {}
                url = url or _ws_to_http(str(xo.get("url", ""))).rstrip("/")
                token = token or str(xo.get("token", ""))
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
    if not url or not token:
        raise XoError(
            "XOA credentials unavailable — set XOA_URL + XOA_TOKEN or make "
            "sops + nix/secrets/secrets.yaml (integrations.xen-orchestra) reachable.")
    return url, token, insecure


# ── REST client (reads) ──────────────────────────────────────────────


class XoRest:
    def __init__(self, url: str | None = None, token: str | None = None,
                 insecure: bool | None = None, timeout: int = 30):
        if url is None or token is None:
            url, token, ins = load_credentials()
            insecure = ins if insecure is None else insecure
        self.base = url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self.ctx = ssl._create_unverified_context() if insecure else None

    def get(self, path: str, fields: list[str] | None = None) -> object:
        target = self.base + "/rest/v0/" + path.lstrip("/")
        if fields:
            target += ("&" if "?" in target else "?") + "fields=" + ",".join(fields)
        req = urllib.request.Request(
            target, headers={"Cookie": f"authenticationToken={self.token}"})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise XoError(f"GET {path} → HTTP {exc.code}: "
                          f"{exc.read().decode('utf-8', 'replace')[:300]}") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise XoError(f"GET {path} failed: {exc}") from exc

    # ── Convenience lookups ──────────────────────────────────────

    def find_vm(self, name: str, *, extra_names: list[str] | None = None,
                ip: str | None = None) -> dict:
        """Resolve a VM by name_label, tolerating fleet-vs-live drift.

        Live labels aren't uniform (some fleets label VMs with an FQDN,
        e.g. fleet key `pve-platform` living as `pve-platform.example.xen`
        on XOA, while others are bare). Resolution order — each step must
        match EXACTLY ONE VM or we move on / fail:
          1. exact name, 2. each extra_names, 3. `<name>.$XOA_VM_DOMAIN`
             (when that env var is set), 4. unique `<name>.` prefix
             match, 5. unique IP match (when given).
        """
        vms = self.get("vms", fields=[
            "name_label", "uuid", "power_state", "memory", "CPUs",
            "addresses", "mainIpAddress", "tags"])
        if not isinstance(vms, list):
            raise XoError("vms collection: unexpected response shape")
        vms = [v for v in vms if isinstance(v, dict)]

        vm_domain = os.environ.get("XOA_VM_DOMAIN", "")
        domain_cand = f"{name}.{vm_domain}" if vm_domain else ""
        for cand in [name, *(extra_names or []), domain_cand]:
            if not cand:
                continue
            matches = [v for v in vms if v.get("name_label") == cand]
            if len(matches) == 1:
                return matches[0]
            if len(matches) > 1:
                raise XoError(f"{len(matches)} VMs named '{cand}' — refusing to guess")

        prefixed = [v for v in vms
                    if str(v.get("name_label", "")).startswith(name + ".")]
        if len(prefixed) == 1:
            return prefixed[0]

        if ip:
            by_ip = [v for v in vms
                     if v.get("mainIpAddress") == ip
                     or ip in (v.get("addresses") or {}).values()]
            if len(by_ip) == 1:
                return by_ip[0]

        raise XoError(f"no VM resolvable from '{name}'"
                      + (f" / ip {ip}" if ip else ""))

    def vm_by_name(self, name: str) -> dict:
        return self.find_vm(name)

    def vm_disks(self, vm_uuid: str) -> list[dict]:
        """[{vdi_uuid, vbd_uuid, name_label, size, device}] for a VM.

        The /vbds collection returns VM/VDI keys without the `$` prefix
        (single-object GETs use $-prefixed) — accept both.
        """
        vbds = self.get("vbds", fields=["uuid", "$VDI", "$VM", "VDI", "VM",
                                        "device", "is_cd_drive", "position"])
        if not isinstance(vbds, list):
            raise XoError("vbds collection: unexpected response shape")
        out: list[dict] = []
        for vbd in vbds:
            if not isinstance(vbd, dict):
                continue
            if (vbd.get("$VM") or vbd.get("VM")) != vm_uuid or vbd.get("is_cd_drive"):
                continue
            vdi_uuid = vbd.get("$VDI") or vbd.get("VDI")
            if not vdi_uuid:
                continue
            vdi = self.get(f"vdis/{vdi_uuid}", fields=["name_label", "size", "uuid"])
            if not isinstance(vdi, dict):
                continue
            out.append({
                "vdi_uuid": vdi_uuid,
                "vbd_uuid": vbd.get("uuid", ""),
                "name_label": vdi.get("name_label", ""),
                "size": int(vdi.get("size") or 0),
                "device": vbd.get("device", "") or str(vbd.get("position", "")),
            })
        return out


    # ── VDI import (INFRA-194 / ADR-022) ─────────────────────────

    def import_vdi(self, sr_uuid: str, name_label: str, path: str,
                   *, raw: bool = False, timeout: int = 3600) -> str:
        """Stream a VHD (raw=False) or raw/ISO (raw=True) disk image into
        an SR via POST /rest/v0/srs/<sr>/vdis; return the new VDI uuid.

        This is the direct-POST upload path the nixos-fleet-bootstrap-v11
        template used ("REST POST raw=false", nix/hosts/xoa/resources.nix)
        — no transient HTTP server needed.
        """
        import urllib.parse
        query = urllib.parse.urlencode(
            {"name_label": name_label, "raw": "true" if raw else "false"})
        target = f"{self.base}/rest/v0/srs/{sr_uuid}/vdis?{query}"
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            req = urllib.request.Request(
                target, data=fh, method="POST",
                headers={
                    "Cookie": f"authenticationToken={self.token}",
                    "Content-Type": "application/octet-stream",
                    "Content-Length": str(size),
                })
            try:
                with urllib.request.urlopen(
                        req, context=self.ctx, timeout=timeout) as resp:
                    body = resp.read().decode("utf-8", "replace").strip()
            except urllib.error.HTTPError as exc:
                raise XoError(
                    f"VDI import → HTTP {exc.code}: "
                    f"{exc.read().decode('utf-8', 'replace')[:300]}") from exc
            except (urllib.error.URLError, TimeoutError) as exc:
                raise XoError(f"VDI import failed: {exc}") from exc
        # Response is the VDI href ("/rest/v0/vdis/<uuid>"), possibly
        # JSON-quoted. Take the last path segment.
        vdi = body.strip('"').rstrip("/").rsplit("/", 1)[-1]
        if not vdi:
            raise XoError(f"VDI import: unparseable response {body!r}")
        return vdi


# ── JSON-RPC websocket client (mutations) ────────────────────────────


class XoRpc:
    """Minimal JSON-RPC 2.0 client over XO's websocket API.

    Speaks the same protocol as upstream `xo-cli` / xo-lib: connect to
    wss://<host>/api/, authenticate with session.signInWithToken, then
    call methods (vdi.set, vm.set, vm.stop, vm.start, vm.snapshot, …).
    """

    def __init__(self, url: str | None = None, token: str | None = None,
                 insecure: bool | None = None, timeout: int = 120):
        import websocket  # deferred: only mutations need it

        if url is None or token is None:
            url, token, ins = load_credentials()
            insecure = ins if insecure is None else insecure
        ws_url = url.rstrip("/")
        if ws_url.startswith("https://"):
            ws_url = "wss://" + ws_url[len("https://"):]
        elif ws_url.startswith("http://"):
            ws_url = "ws://" + ws_url[len("http://"):]
        ws_url += "/api/"

        sslopt = {"cert_reqs": ssl.CERT_NONE} if insecure else None
        try:
            self.ws = websocket.create_connection(ws_url, sslopt=sslopt, timeout=timeout)
        except Exception as exc:
            raise XoError(f"websocket connect to {ws_url} failed: {exc}") from exc
        self._id = 0
        self.call("session.signInWithToken", {"token": token})

    def call(self, method: str, params: dict | None = None,
             timeout: float | None = None) -> object:
        self._id += 1
        rid = self._id
        if timeout is not None:
            self.ws.settimeout(timeout)
        self.ws.send(json.dumps({
            "jsonrpc": "2.0", "id": rid,
            "method": method, "params": params or {},
        }))
        while True:
            try:
                raw = self.ws.recv()
            except Exception as exc:
                raise XoError(f"{method}: websocket recv failed: {exc}") from exc
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(msg, dict) or msg.get("id") != rid:
                continue  # server notification / unrelated frame
            if "error" in msg:
                err = msg["error"]
                raise XoError(f"{method}: {err.get('message', err)} "
                              f"(code {err.get('code')}, data {err.get('data')})")
            return msg.get("result")

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:
            pass

    def __enter__(self) -> "XoRpc":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
