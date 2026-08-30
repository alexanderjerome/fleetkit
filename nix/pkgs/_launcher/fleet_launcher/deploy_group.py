"""fleet deploy — Deployment pipelines.

Groups NixOS/Colmena and Terranix/OpenTofu project commands under a
single ``deploy`` parent.

SKRYBITDEV-599 replaced Pulumi with terranix. The old `sk deploy pulumi`
verb and the `sk deploy infra` end-to-end orchestrator are gone —
provisioning goes through `sk deploy tf <apply|preview|destroy|…>` and
NixOS deploys continue via `sk deploy nixos apply`. See
``docs/adr/adr-015-terranix-replatform.md`` for the rationale.
"""
from __future__ import annotations

import click

from .nixos import nixos
from .pve_install import pve
from .tf_stacks import tf_stacks


@click.group("deploy")
def deploy():
    """Deployment pipelines (nixos / tf).

    Two interfaces:
      nixos — Colmena-based NixOS configuration deployment
      tf    — Terranix/OpenTofu infrastructure provisioning
    """


# ── Compose the deploy group ──────────────────────────────────

deploy.add_command(nixos)
deploy.add_command(pve)
deploy.add_command(tf_stacks, "tf")
