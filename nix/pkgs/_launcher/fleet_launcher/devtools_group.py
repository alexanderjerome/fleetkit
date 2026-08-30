"""fleet devtools — Developer tools and local services.

Groups secrets management and miscellaneous utilities.
"""
from __future__ import annotations

import click

from .secrets import secrets
from .sssd_test import sssd_test
from .utilities import utilities
from .reset_connection import reset_connection


@click.group("devtools")
def devtools():
    """Secrets and developer utilities.

    Groups SOPS secret management, connection-reset tooling, the
    directory-auth probe, and miscellaneous build helpers.
    """


devtools.add_command(secrets)
devtools.add_command(sssd_test)
devtools.add_command(utilities)
devtools.add_command(reset_connection)
