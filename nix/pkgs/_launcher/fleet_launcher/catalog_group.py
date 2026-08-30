"""`sk catalog` — operator helpers for the platform_catalog (ADR-044).

Read + write access to the pricing catalog on app-db (CT 226). Two
sets of commands:

  Read (use SOPS-rendered app role, read-only):
    sk catalog products              — list products
    sk catalog tiers PRODUCT         — list tiers for a product
    sk catalog show PRODUCT TIER     — show one tier
    sk catalog overrides             — list active customer overrides

  Write (use SOPS-rendered owner role; will also publish a
  pricing.changed RabbitMQ event in a future step):
    sk catalog override set USER PRODUCT --reason=R [--fee-pct=N] ...
    sk catalog override clear USER PRODUCT

The owner-side writes are deliberately CLI-only (no admin UI in v1)
so every change ends up in a shell history that's easy to audit.

This wraps `sk remote app-db` calls so the CLI doesn't need direct
network access to the DB host from the operator's WSL/macOS box —
the JWT story is the same as for every other sk command (SSH the
app-db CT and run psql there with the SOPS-rendered DSN).
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

import click


APP_DB_HOST = "app-db"
SCHEMA = "platform_catalog"
APP_ROLE_PW_PATH = "/run/secrets/dbs/app-db/platform_catalog/app/password"
OWNER_ROLE_PW_PATH = "/run/secrets/dbs/app-db/platform_catalog/owner/password"


def _app_db_ip() -> str:
    """SSH target for the app-db host (single-internal — no public ip).

    fleet.toml:  [catalog] app_db_ip = "192.0.2.226"
    """
    from .config import require
    return require("catalog.app_db_ip",
                   "Internal IP of the app-db host, e.g. app_db_ip = \"192.0.2.226\".")


# pricing.changed invalidation event. RabbitMQ management HTTP API
# accepts publish via POST /api/exchanges/{vhost}/{name}/publish.
# Sub'd by every platform-auth PricingClient that was constructed
# with `rabbitmqUrl` set. URL resolution: FLEET_RABBITMQ_MGMT_URL
# env, else fleet.toml [catalog] rabbitmq_mgmt_url; unset ⇒ publish
# is skipped with a notice (best-effort by design).
RABBITMQ_EXCHANGE = "pricing.changed"
RABBITMQ_VHOST = "/"
# Operator credentials. Set via env or read from a SOPS-rendered file
# on a host that holds them. Best-effort: a publish failure is logged
# but doesn't unwind the catalog write — TTL cache eventually catches
# up.
RABBITMQ_USERNAME = os.environ.get("FLEET_RABBITMQ_USER", "")
RABBITMQ_PASSWORD = os.environ.get("FLEET_RABBITMQ_PASSWORD", "")


def _rabbitmq_mgmt_url() -> str:
    from .config import get
    return os.environ.get("FLEET_RABBITMQ_MGMT_URL", "") \
        or get("catalog.rabbitmq_mgmt_url", "")


def _publish_pricing_changed(
    scope: str,
    user_id: str | None = None,
    product_key: str | None = None,
) -> None:
    """Best-effort publish to the pricing.changed exchange.

    Logs + returns on any failure — the catalog write that triggered
    this has already landed; cache subscribers will still pick the
    change up via their TTL.
    """
    mgmt_url = _rabbitmq_mgmt_url()
    if not mgmt_url:
        click.echo(
            "pricing.changed not published (no RabbitMQ management URL; "
            "set FLEET_RABBITMQ_MGMT_URL env or [catalog].rabbitmq_mgmt_url "
            "in fleet.toml)",
            err=True,
        )
        return
    if not RABBITMQ_USERNAME or not RABBITMQ_PASSWORD:
        click.echo(
            "pricing.changed not published (RABBITMQ creds not set; "
            "set FLEET_RABBITMQ_USER + FLEET_RABBITMQ_PASSWORD env)",
            err=True,
        )
        return
    payload: dict = {"scope": scope}
    if user_id is not None:
        payload["user_id"] = user_id
    if product_key is not None:
        payload["product_key"] = product_key
    body = json.dumps({
        "properties": {"content_type": "application/json"},
        "routing_key": "",
        "payload": json.dumps(payload),
        "payload_encoding": "string",
    }).encode()
    vhost_enc = "%2F" if RABBITMQ_VHOST == "/" else RABBITMQ_VHOST
    url = f"{mgmt_url}/api/exchanges/{vhost_enc}/{RABBITMQ_EXCHANGE}/publish"
    auth = base64.b64encode(
        f"{RABBITMQ_USERNAME}:{RABBITMQ_PASSWORD}".encode()
    ).decode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            if not data.get("routed"):
                click.echo(
                    "pricing.changed published but not routed (no subscribers?)",
                    err=True,
                )
    except urllib.error.URLError as e:
        click.echo(f"pricing.changed publish failed: {e}", err=True)


def _remote_psql(role: str, password_path: str, sql: str, *, json_out: bool = False) -> str:
    """Run a psql query on app-db as the given role, returning stdout.

    Reads the SOPS-rendered password file on the host and pipes it via
    PGPASSWORD. `json_out=True` wraps the query in `row_to_json` so the
    caller gets parseable JSON back (works for SELECT statements only).
    """
    if json_out:
        # COALESCE handles the empty-result case — json_agg returns NULL
        # not [] when no rows match, which breaks json.loads on the
        # client side.
        wrapped = (
            f"COPY (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) "
            f"FROM ({sql.rstrip(';')}) t) "
            f"TO STDOUT"
        )
    else:
        wrapped = sql
    inner = (
        f"PGPASSWORD=$(cat {password_path}) "
        f"psql -U {role} -h 127.0.0.1 -d app_db -At -c \"{wrapped}\""
    )
    # SSH directly to the internal IP — single-internal hosts have no
    # public `ip` field for `sk remote` to resolve. Operator already
    # has tailnet access into the internal network.
    result = subprocess.run(
        ["ssh", "-o", "StrictHostKeyChecking=no",
         f"root@{_app_db_ip()}", inner],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        click.echo(result.stderr, err=True)
        sys.exit(result.returncode)
    return result.stdout.strip()


def _read(sql: str, *, json_out: bool = True) -> list[dict]:
    raw = _remote_psql("platform_catalog_app", APP_ROLE_PW_PATH, sql, json_out=json_out)
    if not raw or raw == "":
        return []
    return json.loads(raw)


def _write(sql: str) -> None:
    _remote_psql("platform_catalog_owner", OWNER_ROLE_PW_PATH, sql, json_out=False)


@click.group()
def catalog() -> None:
    """Pricing catalog (platform_catalog on app-db) — ADR-044."""


# ── Read commands ───────────────────────────────────────────────────


@catalog.command("products")
def list_products() -> None:
    """List all products in the catalog."""
    rows = _read(
        f"SELECT key, display_name, billing_model, fallback_policy, fallback_tier_key "
        f"FROM {SCHEMA}.products ORDER BY key"
    )
    if not rows:
        click.echo("(no products)")
        return
    for r in rows:
        click.echo(
            f"  {r['key']:14} {r['billing_model']:14} "
            f"fallback={r['fallback_policy']:11} "
            f"(default tier: {r['fallback_tier_key'] or '-'})"
        )


@catalog.command("tiers")
@click.argument("product")
def list_tiers(product: str) -> None:
    """List active tiers for PRODUCT."""
    rows = _read(
        f"SELECT tier_key, display_name, authentik_group, is_default, "
        f"       fee_pct, min_sats, monthly_usd_cents, included_quota "
        f"FROM {SCHEMA}.tiers "
        f"WHERE product_key = '{product}' "
        f"  AND (effective_until IS NULL OR effective_until > now()) "
        f"ORDER BY tier_key"
    )
    if not rows:
        click.echo(f"(no tiers for product={product})")
        return
    for r in rows:
        default_mark = " *" if r["is_default"] else "  "
        if r["fee_pct"] is not None:
            price = f"fee={r['fee_pct']}% min={r['min_sats']} sats"
        elif r["monthly_usd_cents"] is not None:
            usd = (r["monthly_usd_cents"] or 0) / 100
            price = f"${usd:.2f}/mo quota={r['included_quota'] or '-'}"
        else:
            price = "(negotiated)"
        click.echo(
            f" {default_mark}{r['tier_key']:12} {price:38} "
            f"group={r['authentik_group'] or '-'}"
        )


@catalog.command("show")
@click.argument("product")
@click.argument("tier")
def show_tier(product: str, tier: str) -> None:
    """Show full tier definition."""
    rows = _read(
        f"SELECT * FROM {SCHEMA}.tiers "
        f"WHERE product_key = '{product}' AND tier_key = '{tier}' "
        f"  AND (effective_until IS NULL OR effective_until > now()) "
        f"ORDER BY effective_from DESC LIMIT 1"
    )
    if not rows:
        click.echo(f"(no tier {product}/{tier})", err=True)
        sys.exit(1)
    click.echo(json.dumps(rows[0], indent=2, default=str))


@catalog.command("overrides")
def list_overrides() -> None:
    """List active customer overrides."""
    rows = _read(
        f"SELECT user_id, product_key, reason, reason_detail, "
        f"       fee_pct, min_sats, monthly_usd_cents, "
        f"       effective_from, effective_until "
        f"FROM {SCHEMA}.customer_overrides "
        f"WHERE effective_until IS NULL OR effective_until > now() "
        f"ORDER BY effective_from DESC"
    )
    if not rows:
        click.echo("(no active overrides)")
        return
    for r in rows:
        bits = []
        if r["fee_pct"] is not None:
            bits.append(f"fee={r['fee_pct']}%")
        if r["min_sats"] is not None:
            bits.append(f"min={r['min_sats']}sats")
        if r["monthly_usd_cents"] is not None:
            bits.append(f"${r['monthly_usd_cents']/100:.2f}/mo")
        click.echo(
            f"  {r['user_id']:38} {r['product_key']:10} {','.join(bits) or '-':28} "
            f"({r['reason']})"
        )


# ── Write commands ──────────────────────────────────────────────────


@catalog.group("override")
def override_group() -> None:
    """Manage per-customer pricing overrides."""


@override_group.command("set")
@click.argument("user_id")
@click.argument("product")
@click.option("--reason", required=True, help="Short tag: partner-deal | beta-promo | refund | …")
@click.option("--detail", default="", help="Free-text detail for audit.")
@click.option("--fee-pct", type=float, help="Percent model: fee percentage.")
@click.option("--min-sats", type=int, help="Percent model: floor in sats.")
@click.option("--monthly-usd-cents", type=int, help="Subscription model: monthly USD cents.")
@click.option("--monthly-btc-sats", type=int, help="Subscription model: monthly sats.")
@click.option("--per-unit-usd-cents", type=int, help="Metered model: USD cents per unit.")
@click.option("--per-unit-btc-sats", type=int, help="Metered model: sats per unit.")
@click.option("-y", "--yes", is_flag=True, help="Skip confirmation.")
def override_set(
    user_id: str,
    product: str,
    reason: str,
    detail: str,
    fee_pct: float | None,
    min_sats: int | None,
    monthly_usd_cents: int | None,
    monthly_btc_sats: int | None,
    per_unit_usd_cents: int | None,
    per_unit_btc_sats: int | None,
    yes: bool,
) -> None:
    """Insert a customer pricing override (closes any existing active row)."""
    fields = {
        "fee_pct": fee_pct,
        "min_sats": min_sats,
        "monthly_usd_cents": monthly_usd_cents,
        "monthly_btc_sats": monthly_btc_sats,
        "per_unit_usd_cents": per_unit_usd_cents,
        "per_unit_btc_sats": per_unit_btc_sats,
    }
    set_fields = {k: v for k, v in fields.items() if v is not None}
    if not set_fields:
        click.echo("No pricing fields supplied — nothing to set.", err=True)
        sys.exit(1)

    click.echo(f"Override for user={user_id} product={product}:")
    for k, v in set_fields.items():
        click.echo(f"  {k} = {v}")
    click.echo(f"  reason = {reason}")
    if detail:
        click.echo(f"  detail = {detail}")
    if not yes and not click.confirm("Apply override?"):
        sys.exit(1)

    cols = ["user_id", "product_key", "reason"]
    vals = [f"'{user_id}'", f"'{product}'", f"'{reason}'"]
    if detail:
        cols.append("reason_detail")
        vals.append(f"'{detail.replace(chr(39), chr(39)+chr(39))}'")
    for k, v in set_fields.items():
        cols.append(k)
        vals.append(str(v))

    # Close any active row first so the new one is unambiguously current.
    _write(
        f"UPDATE {SCHEMA}.customer_overrides "
        f"SET effective_until = now() "
        f"WHERE user_id = '{user_id}' AND product_key = '{product}' "
        f"  AND effective_until IS NULL;"
        f"INSERT INTO {SCHEMA}.customer_overrides ({', '.join(cols)}) "
        f"VALUES ({', '.join(vals)});"
    )
    click.echo("Override applied.")
    _publish_pricing_changed("user", user_id=user_id, product_key=product)


@override_group.command("clear")
@click.argument("user_id")
@click.argument("product")
@click.option("-y", "--yes", is_flag=True, help="Skip confirmation.")
def override_clear(user_id: str, product: str, yes: bool) -> None:
    """Mark the active override for (user, product) as expired now."""
    if not yes and not click.confirm(
        f"Clear active override for user={user_id} product={product}?"
    ):
        sys.exit(1)
    _write(
        f"UPDATE {SCHEMA}.customer_overrides "
        f"SET effective_until = now() "
        f"WHERE user_id = '{user_id}' AND product_key = '{product}' "
        f"  AND effective_until IS NULL"
    )
    click.echo("Override cleared.")
    _publish_pricing_changed("user", user_id=user_id, product_key=product)
