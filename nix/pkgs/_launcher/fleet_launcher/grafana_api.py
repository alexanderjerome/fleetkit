"""Minimal Grafana + Synthetic-Monitoring API client — read-only, for
`tf adopt` (INFRA-274).

Two endpoints behind one Grafana Cloud stack, each with its own token:
  - Grafana HTTP API (folders/alerting) at GRAFANA_URL, bearer GRAFANA_AUTH
    (the stack service-account glsa_… token).
  - Synthetic Monitoring API at GRAFANA_SM_URL, bearer GRAFANA_SM_TOKEN.
All four are exported by the launcher bootstrap from SOPS
integrations/grafana_cloud/* (the provider reads the same secrets via
data.sops_file at apply time; a pre-apply Python resolver needs them in env).

Resolves the Grafana-assigned ids the config does not carry:
  - folder title  -> uid           (grafana_folder, grafana_rule_group)
  - SM check job   -> numeric id    (grafana_synthetic_monitoring_check)

Strictly read-only: GET only. Nothing here mutates Grafana.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request


class GrafanaError(RuntimeError):
    """Any failure to REACH or authenticate Grafana — 'I could not look',
    distinct from 'the object is not there'."""


def _get(base_env: str, token_env: str, path: str) -> object:
    base = os.environ.get(base_env, "").rstrip("/")
    token = os.environ.get(token_env, "")
    if not base or not token:
        raise GrafanaError(f"{base_env}/{token_env} unset "
                           "(SOPS integrations/grafana_cloud/*)")
    req = urllib.request.Request(f"{base}{path}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise GrafanaError(f"{path}: HTTP {e.code} {e.reason}") from e
    except Exception as e:  # URLError, timeout, JSON
        raise GrafanaError(f"{path}: {type(e).__name__}: {e}") from e


_folder_uids: dict | None = None


def folder_uid(title: str) -> str | None:
    """uid of the folder with this exact title, or None if none exists.
    Raises GrafanaError if >1 folder shares the title (ambiguous) or the API
    is unreachable. Cached — one /api/folders call per adopt run."""
    global _folder_uids
    if _folder_uids is None:
        res = _get("GRAFANA_URL", "GRAFANA_AUTH", "/api/folders?limit=1000")
        acc: dict = {}
        for f in res if isinstance(res, list) else []:
            if isinstance(f, dict) and f.get("title") and f.get("uid"):
                acc.setdefault(f["title"], set()).add(f["uid"])
        _folder_uids = acc
    uids = _folder_uids.get(title) or set()
    if len(uids) > 1:
        raise GrafanaError(f"{len(uids)} folders titled {title!r} — ambiguous")
    return next(iter(uids), None)


_sm_checks: list | None = None


def sm_check_id(job: str, target: str) -> str | None:
    """Numeric id (as str) of the SM check with this exact job+target, or None.
    Raises GrafanaError if >1 match (ambiguous) or the API is unreachable."""
    global _sm_checks
    if _sm_checks is None:
        res = _get("GRAFANA_SM_URL", "GRAFANA_SM_TOKEN", "/api/v1/check/list")
        _sm_checks = res if isinstance(res, list) else []
    matches = [c for c in _sm_checks
               if isinstance(c, dict) and c.get("job") == job
               and c.get("target") == target]
    if len(matches) > 1:
        raise GrafanaError(
            f"{len(matches)} SM checks for job={job!r} target={target!r} — ambiguous")
    return str(matches[0]["id"]) if matches and matches[0].get("id") is not None else None
