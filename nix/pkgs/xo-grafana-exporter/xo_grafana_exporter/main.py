"""xo-grafana-exporter — Prometheus exporter for the XCP-ng tier via the
Xen Orchestra REST API (INFRA-40).

Why this exists: our XOA edition does not ship the official OpenMetrics
plugin (plugin.get lists only telemetry + xoa), and we hold no dom0
credentials — XO's REST API is the only metrics surface available. Every
scrape fetches live from `/rest/v0` (no internal caching); host/VM RRD
series come from the `/stats` endpoints at 5-second granularity and the
last non-null sample of each series is exported.

All metrics are prefixed `xoa_` so they can never collide with the
official plugin's `xcp_`/`xo_` namespaces if a future XOA tier adds it.

Configuration (env):
  XOA_URL              required — https:// (wss:// from SOPS is auto-converted)
  XOA_TOKEN            XO authentication token, or
  XOA_TOKEN_FILE       path to a file holding the token (systemd LoadCredential)
  XO_EXPORTER_ADDR     listen address           (default 0.0.0.0)
  XO_EXPORTER_PORT     listen port              (default 9603)
  XO_EXPORTER_TIMEOUT  per-request timeout, s   (default 10)
  XO_EXPORTER_WORKERS  parallel stats fetches   (default 8)
  XO_EXPORTER_PER_CPU  "1" → per-core cpu series instead of just the average
  XO_EXPORTER_VERIFY_TLS  "1" → verify XO's TLS cert (default off: self-signed)
"""

import concurrent.futures
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ── XO REST client ──────────────────────────────────────────────────────


class XoClient:
    def __init__(self, url, token, timeout, verify_tls):
        self.base = url.rstrip("/")
        self.headers = {"Cookie": "authenticationToken=" + token}
        self.timeout = timeout
        self.ctx = None if verify_tls else ssl._create_unverified_context()

    def get(self, path):
        req = urllib.request.Request(self.base + path, headers=self.headers)
        with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
            return json.loads(r.read().decode("utf-8"))


# ── Prometheus text rendering ───────────────────────────────────────────


def _esc(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class Metrics:
    """Accumulates samples and renders Prometheus text exposition format."""

    def __init__(self):
        self._families = {}  # name -> (help, type, [(labels, value)])

    def add(self, name, help_text, mtype="gauge"):
        self._families.setdefault(name, (help_text, mtype, []))

    def sample(self, name, labels, value):
        if value is None:
            return
        self._families[name][2].append((labels, float(value)))

    def render(self):
        out = []
        for name, (help_text, mtype, samples) in self._families.items():
            if not samples:
                continue
            out.append(f"# HELP {name} {help_text}")
            out.append(f"# TYPE {name} {mtype}")
            for labels, value in samples:
                if labels:
                    lbl = ",".join(f'{k}="{_esc(v)}"' for k, v in sorted(labels.items()))
                    out.append(f"{name}{{{lbl}}} {value}")
                else:
                    out.append(f"{name} {value}")
        return "\n".join(out) + "\n"


def last_value(series):
    """Last non-null sample of an RRD series (newest entries at the end)."""
    if not isinstance(series, list):
        return None
    for v in reversed(series):
        if v is not None:
            return v
    return None


# ── collectors ──────────────────────────────────────────────────────────


def collect(xo, per_cpu, workers):
    t0 = time.monotonic()
    m = Metrics()
    errors = 0

    m.add("xoa_up", "1 if the XO REST API answered the collection queries")
    m.add("xoa_scrape_duration_seconds", "Wall time of the full live collection")
    m.add("xoa_scrape_errors", "Per-object fetch errors during this scrape")

    try:
        fields = "uuid,name_label,power_state,memory,cpus,CPUs,enabled,rebootRequired,residentVms,version,productBrand,$poolId,$container"
        hosts = xo.get(f"/rest/v0/hosts?fields={fields}")
        vms = xo.get(f"/rest/v0/vms?fields={fields}")
        srs = xo.get("/rest/v0/srs?fields=uuid,name_label,SR_type,shared,size,physical_usage,usage,$poolId")
        pools = xo.get("/rest/v0/pools?fields=uuid,name_label")
        alarms = xo.get("/rest/v0/alarms")
    except Exception as exc:  # noqa: BLE001 — any API failure means "down"
        print(f"collection failed: {exc}", file=sys.stderr)
        m.sample("xoa_up", {}, 0)
        m.sample("xoa_scrape_duration_seconds", {}, time.monotonic() - t0)
        return m

    pool_names = {p["uuid"]: p["name_label"] for p in pools}
    host_names = {h["uuid"]: h["name_label"] for h in hosts}

    # ── hosts (object state) ──
    m.add("xoa_host_info", "Static host facts (always 1)")
    m.add("xoa_host_enabled", "1 if the host is enabled in the pool")
    m.add("xoa_host_reboot_required", "1 if XAPI flags a pending reboot")
    m.add("xoa_host_memory_size_bytes", "Physical memory")
    m.add("xoa_host_memory_usage_bytes", "Memory in use (XAPI view)")
    m.add("xoa_host_cpu_cores", "Physical cores")
    m.add("xoa_host_resident_vms", "VMs resident on this host")
    for h in hosts:
        base = {"uuid": h["uuid"], "host": h["name_label"],
                "pool": pool_names.get(h.get("$poolId"), "")}
        m.sample("xoa_host_info", {**base,
                                   "version": h.get("version", ""),
                                   "product": h.get("productBrand", "")}, 1)
        m.sample("xoa_host_enabled", base, 1 if h.get("enabled") else 0)
        m.sample("xoa_host_reboot_required", base, 1 if h.get("rebootRequired") else 0)
        m.sample("xoa_host_memory_size_bytes", base, h.get("memory", {}).get("size"))
        m.sample("xoa_host_memory_usage_bytes", base, h.get("memory", {}).get("usage"))
        m.sample("xoa_host_cpu_cores", base, (h.get("cpus") or {}).get("cores"))
        m.sample("xoa_host_resident_vms", base, len(h.get("residentVms") or []))

    # ── VMs (object state) ──
    m.add("xoa_vm_info", "Static VM facts (always 1)")
    m.add("xoa_vm_running", "1 if power_state is Running")
    m.add("xoa_vm_memory_size_bytes", "Configured memory")
    m.add("xoa_vm_vcpus", "Configured vCPUs")
    for v in vms:
        base = {"uuid": v["uuid"], "vm": v["name_label"],
                "host": host_names.get(v.get("$container"), "")}
        m.sample("xoa_vm_info", {**base, "power_state": v.get("power_state", "")}, 1)
        m.sample("xoa_vm_running", base, 1 if v.get("power_state") == "Running" else 0)
        m.sample("xoa_vm_memory_size_bytes", base, v.get("memory", {}).get("size"))
        m.sample("xoa_vm_vcpus", base, (v.get("CPUs") or {}).get("number"))

    # ── SRs ──
    m.add("xoa_sr_size_bytes", "SR physical size")
    m.add("xoa_sr_physical_usage_bytes", "Physically used space")
    m.add("xoa_sr_allocated_bytes", "Virtual allocation (sum of VDI sizes)")
    for s in srs:
        base = {"uuid": s["uuid"], "sr": s["name_label"],
                "sr_type": s.get("SR_type", ""), "shared": str(bool(s.get("shared"))).lower(),
                "pool": pool_names.get(s.get("$poolId"), "")}
        # XAPI reports -1 for SRs it cannot size (udev, iso) — skip those.
        for metric, key in (("xoa_sr_size_bytes", "size"),
                            ("xoa_sr_physical_usage_bytes", "physical_usage"),
                            ("xoa_sr_allocated_bytes", "usage")):
            value = s.get(key)
            if value is not None and value >= 0:
                m.sample(metric, base, value)

    # ── alarms ──
    m.add("xoa_alarms", "Active XAPI alarms visible to XO")
    m.sample("xoa_alarms", {}, len(alarms))

    # ── live RRD stats (5 s granularity, last sample of each series) ──
    m.add("xoa_host_cpu_percent", "Host CPU usage %% (avg over cores, or per core with XO_EXPORTER_PER_CPU)")
    m.add("xoa_host_load", "Host load average")
    m.add("xoa_host_memory_free_bytes", "Free memory (RRD)")
    m.add("xoa_host_pif_rx_bytes_per_second", "PIF receive throughput")
    m.add("xoa_host_pif_tx_bytes_per_second", "PIF transmit throughput")
    m.add("xoa_vm_cpu_percent", "VM CPU usage %% (avg over vCPUs, or per vCPU with XO_EXPORTER_PER_CPU)")
    m.add("xoa_vm_memory_free_bytes", "Guest-reported free memory (needs guest tools)")
    m.add("xoa_vm_vif_rx_bytes_per_second", "VIF receive throughput")
    m.add("xoa_vm_vif_tx_bytes_per_second", "VIF transmit throughput")
    m.add("xoa_vm_disk_read_bytes_per_second", "Virtual disk read throughput")
    m.add("xoa_vm_disk_write_bytes_per_second", "Virtual disk write throughput")

    def cpu_samples(metric, base, stats):
        cpus = stats.get("cpus") or {}
        values = {idx: last_value(s) for idx, s in cpus.items()}
        values = {k: v for k, v in values.items() if v is not None}
        if not values:
            return
        if per_cpu:
            for idx, v in values.items():
                m.sample(metric, {**base, "cpu": idx}, v)
        else:
            m.sample(metric, base, sum(values.values()) / len(values))

    def indexed_samples(metric, base, tree, label):
        for idx, series in (tree or {}).items():
            m.sample(metric, {**base, label: idx}, last_value(series))

    def fetch_host_stats(h):
        base = {"uuid": h["uuid"], "host": h["name_label"]}
        stats = xo.get(f"/rest/v0/hosts/{h['uuid']}/stats?granularity=seconds")["stats"]
        cpu_samples("xoa_host_cpu_percent", base, stats)
        m.sample("xoa_host_load", base, last_value(stats.get("load")))
        m.sample("xoa_host_memory_free_bytes", base, last_value(stats.get("memoryFree")))
        indexed_samples("xoa_host_pif_rx_bytes_per_second", base, (stats.get("pifs") or {}).get("rx"), "pif")
        indexed_samples("xoa_host_pif_tx_bytes_per_second", base, (stats.get("pifs") or {}).get("tx"), "pif")

    def fetch_vm_stats(v):
        base = {"uuid": v["uuid"], "vm": v["name_label"],
                "host": host_names.get(v.get("$container"), "")}
        stats = xo.get(f"/rest/v0/vms/{v['uuid']}/stats?granularity=seconds")["stats"]
        cpu_samples("xoa_vm_cpu_percent", base, stats)
        m.sample("xoa_vm_memory_free_bytes", base, last_value(stats.get("memoryFree")))
        indexed_samples("xoa_vm_vif_rx_bytes_per_second", base, (stats.get("vifs") or {}).get("rx"), "vif")
        indexed_samples("xoa_vm_vif_tx_bytes_per_second", base, (stats.get("vifs") or {}).get("tx"), "vif")
        indexed_samples("xoa_vm_disk_read_bytes_per_second", base, (stats.get("xvds") or {}).get("r"), "disk")
        indexed_samples("xoa_vm_disk_write_bytes_per_second", base, (stats.get("xvds") or {}).get("w"), "disk")

    jobs = [(fetch_host_stats, h) for h in hosts]
    jobs += [(fetch_vm_stats, v) for v in vms if v.get("power_state") == "Running"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(fn, obj): obj for fn, obj in jobs}
        for fut in concurrent.futures.as_completed(futures):
            try:
                fut.result()
            except Exception as exc:  # noqa: BLE001 — one object must not kill the scrape
                errors += 1
                obj = futures[fut]
                print(f"stats fetch failed for {obj.get('name_label')}: {exc}", file=sys.stderr)

    m.sample("xoa_up", {}, 1)
    m.sample("xoa_scrape_errors", {}, errors)
    m.sample("xoa_scrape_duration_seconds", {}, time.monotonic() - t0)
    return m


# ── HTTP server ─────────────────────────────────────────────────────────


def make_handler(xo, per_cpu, workers):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                body = b'{"status":"ok"}'
                ctype = "application/json"
            elif self.path in ("/", "/metrics"):
                body = collect(xo, per_cpu, workers).render().encode("utf-8")
                ctype = "text/plain; version=0.0.4; charset=utf-8"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):  # quiet per-request access log
            pass

    return Handler


def main():
    url = os.environ.get("XOA_URL")
    if not url:
        sys.exit("XOA_URL is required")
    # SOPS stores the websocket URL for the Terraform provider; REST is
    # plain https on the same listener.
    url = url.replace("wss://", "https://", 1).replace("ws://", "http://", 1)

    token = os.environ.get("XOA_TOKEN")
    token_file = os.environ.get("XOA_TOKEN_FILE")
    if not token and token_file:
        with open(token_file) as fh:
            token = fh.read().strip()
    if not token:
        sys.exit("XOA_TOKEN or XOA_TOKEN_FILE is required")

    addr = os.environ.get("XO_EXPORTER_ADDR", "0.0.0.0")
    port = int(os.environ.get("XO_EXPORTER_PORT", "9603"))
    timeout = float(os.environ.get("XO_EXPORTER_TIMEOUT", "10"))
    workers = int(os.environ.get("XO_EXPORTER_WORKERS", "8"))
    per_cpu = os.environ.get("XO_EXPORTER_PER_CPU") == "1"
    verify_tls = os.environ.get("XO_EXPORTER_VERIFY_TLS") == "1"

    xo = XoClient(url, token, timeout, verify_tls)
    server = ThreadingHTTPServer((addr, port), make_handler(xo, per_cpu, workers))
    print(f"xo-grafana-exporter listening on {addr}:{port}, upstream {url}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
