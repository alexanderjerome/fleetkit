"""fleet bootstraps — One-time setup and platform utilities.

Groups Hiro snapshot bootstrapping and Proxmox VE host management
under a single ``bootstraps`` parent.

NOTE (INFRA-86 / ADR-047): the per-container ``bootstraps container``
command has been RETIRED. Fresh NixOS LXCs no longer need a manual
network/SSH injection step — PVE 9's NixOS setup plugin writes the
static IP from the container's ``ip_config`` at create time (ostype
``nixos``), and the LXC template (built + published to the NFS store by
nix-builder's template factory) already bakes in the sysadmin SSH key.
A container is reachable at its declared ``internal_ip`` straight after
``sk deploy tf apply``; go straight to ``sk deploy nixos apply host <name>``.
"""
from __future__ import annotations

import click

from .pve import pve
from .step_ca import bootstrap_step_ca


@click.group("bootstraps")
def bootstraps():
    """One-time setup and platform utilities.

    Groups initial bootstrapping tasks: Hiro snapshot sync and
    Proxmox VE host setup.
    """


# hiro is added in main.py (external package import)
bootstraps.add_command(pve)
bootstraps.add_command(bootstrap_step_ca)
