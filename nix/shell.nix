# nix/shell.nix — fleetkit operator devshell.
#
# TOOLS ONLY, by design. The shell provides the toolchain (tofu, colmena,
# sops, ansible, the venv for the fleet CLI) and nothing else: every piece
# of runtime environment — provider credentials, ansible paths, the tofu
# plugin cache, the age key — is provisioned by the `fleet` CLI itself at
# invocation time, from the fleet catalog + the SOPS store. Nothing here should
# require (or leak) knowledge of a specific fleet.
#
# Consumer repos that need extra tools or env (app CLIs, DB DSNs, language
# runtimes) pass `extraPackages` / `extraShellHook` via fleetkit.lib.mkDevShell.
{ pkgs, mode ? "dev", extraPackages ? [], extraShellHook ? "", fleet ? null }:

let
  # Fleet eval for the one operator convenience the shell itself provides:
  # remote-builder discovery + loading the deploy key into ssh-agent
  # (interactive niceties that must exist BEFORE the CLI runs). Consumers
  # pass their mkFleet result as `fleet`; standalone the framework fleet
  # is empty and every use below must tolerate that.
  fleetEval =
    if fleet != null then fleet.fleetEval
    else (pkgs.lib.evalModules {
      modules = [ ./fleet ];
    }).config.fleet;
  hostsLib = import ./lib/inventory.nix { hosts = fleetEval.hostsJson; };
  builderIp = hostsLib.ipByTag "builder";

  isCi = mode == "ci";

  commonPackages = with pkgs; [
    nix
    git
  ];

  devPackages = with pkgs; [
    (python313.withPackages (ps: with ps; [ click requests httpx ]))
    uv

    # Infrastructure — OpenTofu (terranix emits its JSON config).
    opentofu
    # S3-compatible state backend tooling.
    awscli2

    # Secrets
    sops
    age
    ssh-to-age

    # NixOS deployment
    colmena

    # The fleet CLI is provided by the consumer venv (editable install
    # via uv) during development; `nix build .#fleet` for the package.

    # Config management for non-NixOS guests
    ansible

    # Proxmox VE remote CLI — read-only cluster exploration.
    (pkgs.callPackage ./pkgs/pve-cli { })

    # Utilities
    just
    jq
    yq-go
    aria2
  ];

  ciPackages = with pkgs; [
    jq
    coreutils
  ];

  selectedPackages =
    extraPackages
    ++ commonPackages
    ++ (if isCi then ciPackages else devPackages);

  devShellHook = ''
    # Root via git, not $PWD — entering the shell from a subdirectory must
    # not create a second .venv there.
    FLEET_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    export UV_PROJECT_ENVIRONMENT="$FLEET_REPO_ROOT/.venv"

    # Sync venv from pyproject.toml via uv (when the consumer repo has
    # one). Failures must say so, not vanish silently.
    if command -v uv >/dev/null 2>&1 && [ -f "$FLEET_REPO_ROOT/pyproject.toml" ]; then
      uv sync --quiet || echo "WARNING: uv sync failed — .venv (and the fleet CLI) may be stale or missing" >&2
    fi
    # Activate WITHOUT sourcing .venv/bin/activate: activate scripts
    # hardcode the venv-creation-time path, which breaks after repo moves.
    if [ -d "$UV_PROJECT_ENVIRONMENT/bin" ]; then
      export VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"
      export PATH="$VIRTUAL_ENV/bin:$PATH"
    fi

    # SSH agent + deploy key — interactive convenience so colmena/ssh
    # don't prompt per-host. Key path comes from the fleet manifest
    # (fleet.network.sysadmin_key_file), the one fleet-specific value the
    # shell touches; everything else is the CLI's job.
    if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
      eval $(ssh-agent -s) > /dev/null
      trap "ssh-agent -k > /dev/null 2>&1" EXIT
    fi
    SYSADMIN_KEY="${fleetEval.network.sysadmin_key_file}"
    SYSADMIN_KEY="''${SYSADMIN_KEY/#\~/''${HOME}}"
    if [ -f "$SYSADMIN_KEY" ]; then
      ssh-add -l 2>/dev/null | grep -q "$(basename "$SYSADMIN_KEY")" || ssh-add "$SYSADMIN_KEY" 2>/dev/null
    fi
  '' + (if builderIp != null then ''
    # Remote builder — offload Nix builds to the fleet builder host
    # (silent unless reachable).
    BUILDER_IP="${builderIp}"
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$BUILDER_IP" true 2>/dev/null; then
      mkdir -p /tmp/nix-builder
      cat > /tmp/nix-builder/machines <<MACHINES
ssh://root@$BUILDER_IP x86_64-linux ''${SYSADMIN_KEY} 8 1 big-parallel,kvm
MACHINES
      export NIX_REMOTE_SYSTEMS="/tmp/nix-builder/machines"
    fi
  '' else "") + extraShellHook;

  ciShellHook = ''
    echo "ci shell ready — nix $(nix --version 2>/dev/null | awk '{print $NF}')."
  '' + extraShellHook;
in
pkgs.mkShell {
  packages = selectedPackages;

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];

  shellHook = if isCi then ciShellHook else devShellHook;
}
