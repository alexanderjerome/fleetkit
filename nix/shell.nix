# nix/shell.nix — fleetkit operator devshell.
#
# Generic toolchain + environment wiring only. Consumer repos that need
# extra tools or env (app CLIs, DB DSNs, language runtimes) pass
# `extraPackages` / `extraShellHook` from their own flake — nothing
# environment-specific may live here.
{ pkgs, mode ? "dev", extraPackages ? [], extraShellHook ? "", fleet ? null }:

let
  # Fleet eval for operator conveniences (remote-builder discovery,
  # sysadmin key path). Consumers pass their mkFleet result as `fleet`
  # (via fleetkit.lib.mkDevShell); standalone the framework fleet is
  # empty and every use below must tolerate that.
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
    (pkgs.callPackage ./pkgs/cv4pve-cli { })

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

    # Fallback: source .env if it exists
    if [ -f .env ]; then
      set -a
      source .env
      set +a
    fi

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

    # SSH agent — load the sysadmin key for Colmena/SSH access to fleet hosts.
    if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
      eval $(ssh-agent -s) > /dev/null
      trap "ssh-agent -k > /dev/null 2>&1" EXIT
    fi
    # Sysadmin private key — single source of truth: fleet.network.sysadmin_key_file.
    SYSADMIN_KEY="${fleetEval.network.sysadmin_key_file}"
    SYSADMIN_KEY="''${SYSADMIN_KEY/#\~/''${HOME}}"
    export SK_SYSADMIN_KEY_FILE="$SYSADMIN_KEY"
    if [ -f "$SYSADMIN_KEY" ]; then
      ssh-add -l 2>/dev/null | grep -q "$(basename "$SYSADMIN_KEY")" || ssh-add "$SYSADMIN_KEY" 2>/dev/null
    fi

    # SOPS age key — operator-local file; never a literal in this repo.
    export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.ssh/sops-age.key}"

    # Ansible — root the config/roles/inventory at the consumer repo
    # (only when it ships an ansible/ tree).
    if [ -d "$FLEET_REPO_ROOT/ansible" ]; then
      export ANSIBLE_CONFIG="$FLEET_REPO_ROOT/ansible/ansible.cfg"
      export ANSIBLE_ROLES_PATH="$FLEET_REPO_ROOT/ansible/roles"
      export ANSIBLE_INVENTORY="$FLEET_REPO_ROOT/ansible/inventory/static.yml"
      export ANSIBLE_HOST_KEY_CHECKING=False
    fi

    # OpenTofu provider plugin cache — one global store every
    # .tf/<slug>/ workdir hardlinks into. Must exist before tofu runs
    # or the setting is silently ignored.
    export TF_PLUGIN_CACHE_DIR="''${TF_PLUGIN_CACHE_DIR:-$HOME/.cache/opentofu/plugin-cache}"
    mkdir -p "$TF_PLUGIN_CACHE_DIR"

    # Provider/state credentials from the consumer SOPS store (layout
    # convention: integrations/{aws,proxmox} in nix/secrets/secrets.yaml).
    if [ -f "$FLEET_REPO_ROOT/nix/secrets/secrets.yaml" ]; then
      _aws_secrets=$(sops -d --extract '["integrations"]["aws"]' "$FLEET_REPO_ROOT/nix/secrets/secrets.yaml" 2>/dev/null || true)
      if [ -n "$_aws_secrets" ]; then
        export AWS_ACCESS_KEY_ID="$(echo "$_aws_secrets" | ${pkgs.yq-go}/bin/yq '.access_key_id')"
        export AWS_SECRET_ACCESS_KEY="$(echo "$_aws_secrets" | ${pkgs.yq-go}/bin/yq '.secret_access_key')"
        export AWS_DEFAULT_REGION="$(echo "$_aws_secrets" | ${pkgs.yq-go}/bin/yq '.region')"
      fi
      unset _aws_secrets
      _pve_json=$(${pkgs.sops}/bin/sops -d --output-type json "$FLEET_REPO_ROOT/nix/secrets/secrets.yaml" 2>/dev/null || true)
      if [ -n "$_pve_json" ]; then
        export PROXMOX_VE_ENDPOINT="$(echo "$_pve_json" | ${pkgs.jq}/bin/jq -r '.integrations.proxmox.endpoint // empty')"
        export PROXMOX_VE_USERNAME="$(echo "$_pve_json" | ${pkgs.jq}/bin/jq -r '.integrations.proxmox.username // empty')"
        export PROXMOX_VE_PASSWORD="$(echo "$_pve_json" | ${pkgs.jq}/bin/jq -r '.integrations.proxmox.password // empty')"
        export PROXMOX_VE_INSECURE=true
      fi
      unset _pve_json
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
