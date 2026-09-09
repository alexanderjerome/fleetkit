"""Minimal Cloudflare API v4 client — read-only, for `tf adopt` (INFRA-274).

Resolves a declared `cloudflare_record` to its Terraform import id
(`<zone_id>/<record_id>`) by looking the zone up by name and the record up by
name+type+content. Reads `CLOUDFLARE_API_TOKEN` from the environment (exported
by the launcher bootstrap from SOPS integrations/cloudflare/api_token — the
terraform provider reads the same secret via data.sops_file at apply time, but
that is unavailable to a pre-apply Python resolver).

Strictly read-only: it only ever GETs. Nothing here mutates a zone.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request

_API = "https://api.cloudflare.com/client/v4"


class CloudflareError(RuntimeError):
    """Raised for any failure to REACH or authenticate Cloudflare — an
    'I could not look' answer, distinct from 'the record is not there'."""


def _token() -> str:
    tok = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not tok:
        raise CloudflareError(
            "CLOUDFLARE_API_TOKEN unset (SOPS integrations/cloudflare/api_token)")
    return tok


def _get(path: str, params: dict | None = None) -> list:
    url = f"{_API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {_token()}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise CloudflareError(f"{path}: HTTP {e.code} {e.reason}") from e
    except Exception as e:  # URLError, timeout, JSON — all "could not look"
        raise CloudflareError(f"{path}: {type(e).__name__}: {e}") from e
    if not body.get("success", False):
        raise CloudflareError(f"{path}: {body.get('errors')}")
    return body.get("result") or []


_zone_ids: dict = {}


def zone_id(zone_name: str) -> str | None:
    """Zone id for an exact zone name, or None if the token cannot see it.
    Cached — one lookup per distinct zone across a whole adopt run."""
    if zone_name not in _zone_ids:
        res = _get("/zones", {"name": zone_name})
        _zone_ids[zone_name] = res[0]["id"] if res else None
    return _zone_ids[zone_name]


def list_dns_records(zid: str, name: str, rtype: str) -> list[dict]:
    """Live {id, content} for every record in `zid` at this exact name+type.
    name+type identifies THE record a config entry manages; when more than one
    exists (round-robin), the caller uses `content` to pick. Returns [] when
    nothing is there (a genuine not-provisioned-yet)."""
    res = _get(f"/zones/{zid}/dns_records", {"name": name, "type": rtype})
    return [{"id": r["id"], "content": r.get("content")}
            for r in res if isinstance(r, dict) and r.get("id")]
