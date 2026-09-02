"""fleet pki — PKI / certificate operations (ADR-026).

    fleet pki acme-dns register <host>

Registers a fleet host with the acme-dns delegation server, stores the
returned scoped credential in SOPS, and prints the CNAME the host needs.
This replaces putting the raw zone-wide Cloudflare token on the host: the
host's Caddy then solves Let's Encrypt DNS-01 for `<host>.<domains.base>` with
this low-privilege credential (it can write only its own challenge record).

Runtime prerequisites (this command talks to a LIVE acme-dns):
  - acme-dns running on the edge (infra.pki.acmeDns.enable) and its update API
    reachable from where you run this (fleet.settings.pki.acmeDnsApiBase,
    e.g. "http://192.0.2.100:8081", or --api-base).
  - SOPS age key available ($FLEET_AGE_KEY_FILE / ~/.ssh/sops-age.key) to write the credential.

After registering, add the printed `<host> = "<fulldomain>";` line to
`acmeDnsDelegations` in nix/fleet/dns/inputs.nix (emits the _acme-challenge
CNAME), set `infra.ingress.devCertIssuer = "acmedns"` on the host, then deploy.
"""
from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

import click
from rich.console import Console

from ._util import find_project_root, fleet_cache_dir
from .secrets import _sops_set, _find_secrets_file, _ensure_age_key

console = Console()


def _host_internal_ip(host: str) -> str | None:
    """Look up a host's internal IP from the generated inventory."""
    hosts_file = fleet_cache_dir() / "hosts.json"
    if not hosts_file.exists():
        return None
    entry = json.loads(hosts_file.read_text()).get(host, {})
    return entry.get("internal_ip") or entry.get("ip")


def _acme_dns_register(api_base: str, allowfrom: list[str]) -> dict:
    """POST /register to acme-dns and return the credential JSON."""
    body = json.dumps({"allowfrom": allowfrom}).encode() if allowfrom else b"{}"
    req = urllib.request.Request(
        f"{api_base.rstrip('/')}/register",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310 (trusted internal endpoint)
        return json.loads(resp.read().decode())


@click.group("pki")
def pki() -> None:
    """PKI / certificate operations (ADR-026)."""


@pki.group("acme-dns")
def acme_dns() -> None:
    """acme-dns delegation credential management."""


@acme_dns.command("register")
@click.argument("host")
@click.option("--api-base", default=None,
              help="acme-dns update API base URL (the edge acme-dns host). "
                   "Defaults to fleet.settings.pki.acmeDnsApiBase.")
@click.option("--restrict/--no-restrict", default=True,
              help="Restrict the credential to the host's internal IP (allowfrom). Default: restrict.")
def register(host: str, api_base: str | None, restrict: bool) -> None:
    """Register HOST with acme-dns and store its scoped credential in SOPS.

    HOST is the fleet.compute key (e.g. observe, devops, ingress).
    """
    if not api_base:
        from .config import require
        api_base = require("pki.acme_dns_api_base",
                           "acme-dns update API base URL, e.g. "
                           "acme_dns_api_base = \"http://192.0.2.100:8081\" "
                           "(or pass --api-base).")
    _ensure_age_key()
    # acme-dns credentials are integrations.* — write them where that
    # tree actually lives, or they land in a file nothing reads.
    from .config import file_for as _file_for
    secrets_file = str(_file_for("integrations"))

    # Restrict the credential to the host's own IP where we can resolve it,
    # so a leaked credential can't be used from elsewhere to update the TXT.
    allowfrom: list[str] = []
    if restrict:
        ip = _host_internal_ip(host)
        if ip:
            allowfrom = [f"{ip}/32"]
            console.print(f"  Restricting credential to [cyan]{ip}/32[/cyan]")
        else:
            console.print(f"[yellow]WARNING:[/yellow] {host} not found in hosts.json — "
                          "registering without an allowfrom restriction.")

    console.print(f"[bold]Registering {host} with acme-dns at {api_base}…[/bold]")
    try:
        cred = _acme_dns_register(api_base, allowfrom)
    except Exception as exc:  # noqa: BLE001
        console.print(f"[red]ERROR:[/red] acme-dns /register failed: {exc}")
        console.print("[dim]Is acme-dns running and its update API reachable from here?[/dim]")
        sys.exit(1)

    fulldomain = cred["fulldomain"]
    base = f"integrations/acme-dns/{host}"
    _sops_set(secrets_file, f"{base}/username", cred["username"])
    _sops_set(secrets_file, f"{base}/password", cred["password"])
    _sops_set(secrets_file, f"{base}/subdomain", cred["subdomain"])
    console.print(f"[green]Stored credential[/green] under [cyan]{base}/{{username,password,subdomain}}[/cyan]")

    console.print("\n[bold]Next steps:[/bold]")
    console.print("  1. Add the delegation CNAME source — in "
                  "[cyan]nix/fleet/dns/inputs.nix[/cyan] → [cyan]acmeDnsDelegations[/cyan]:")
    console.print(f'       [green]{host}[/green] = "[green]{fulldomain}[/green]";')
    console.print("  2. Set [cyan]infra.ingress.devCertIssuer = \"acmedns\";[/cyan] on the host.")
    console.print("  3. [cyan]fleet deploy tf apply platform.dns[/cyan] (emit the CNAME) then "
                  "[cyan]fleet deploy nixos apply host " + host + "[/cyan].")
