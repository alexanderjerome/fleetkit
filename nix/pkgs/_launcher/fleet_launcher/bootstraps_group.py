"""fleet bootstraps — One-time setup and platform utilities.

Groups Proxmox VE host setup and step-ca PKI bootstrap under a single
``bootstraps`` parent.

NOTE: there is deliberately NO per-container bootstrap command. Fresh
NixOS LXCs need no manual network/SSH injection step — PVE 9's NixOS
setup plugin writes the static IP from the container's ``ip_config`` at
create time (ostype ``nixos``), and the LXC template already bakes in
the sysadmin SSH key. A container is reachable at its declared
``internal_ip`` straight after ``fleet deploy tf apply``; go straight to
``fleet deploy nixos apply host <name>``.
"""
from __future__ import annotations

import click

from .pve import pve
from .step_ca import bootstrap_step_ca


@click.group("bootstraps")
def bootstraps():
    """One-time setup and platform utilities.

    Groups initial bootstrapping tasks: Proxmox VE host setup and
    step-ca PKI initialization.
    """


bootstraps.add_command(pve)
bootstraps.add_command(bootstrap_step_ca)
