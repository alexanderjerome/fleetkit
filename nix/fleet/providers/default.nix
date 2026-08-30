{ lib, ... }:

# Provider & instance registry (SKRYBITDEV-599 schema v2) — schema only.
#
# Each entry describes HOW to talk to one physical provider endpoint.
# Resources in fleet.compute / fleet.resources reference these via
# `provider_instance = "<provider>.<instance>"`.
#
# Secrets are referenced by SOPS path, resolved at `tofu apply` time
# via the carlpett/sops provider. Plaintext values never land in the
# generated config.tf.json.
#
# Values are supplied by the consumer repo (fleetkit is schema-only here).

let
  providerInstanceType = lib.types.submodule ({ name, ... }: {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = "Terraform provider source address (e.g. bpg/proxmox).";
      };
      version = lib.mkOption {
        type = lib.types.str;
        description = "Version constraint for required_providers.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "API endpoint URL. Optional — provider may derive from secrets.";
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = ''
          Map of provider-config-key → SOPS path. Emitter resolves each
          to `$${data.sops_file.secrets.data["<dotted-path>"]}` so secrets
          never appear in config.tf.json.
        '';
      };
      insecure = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Skip TLS verification (internal step-ca cert).";
      };
      state = {
        prefix = lib.mkOption {
          type = lib.types.str;
          description = "S3 key prefix for this instance's tfstate(s). Full path: s3://<bucket>/<prefix>/<stack>/terraform.tfstate";
        };
      };
      destruction_policy = lib.mkOption {
        type = lib.types.enum [ "strict" "standard" "permissive" ];
        default = "standard";
        description = ''
          - strict: emit prevent_destroy=true on EVERY resource in this instance
          - standard: emit prevent_destroy=true only on stateful-tagged resources
          - permissive: emit prevent_destroy only on explicit protect=true
        '';
      };
      cluster = lib.mkOption {
        type = lib.types.submodule {
          options = {
            nodes = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
            primary_node = lib.mkOption { type = lib.types.str; default = ""; };
            ha_manager = lib.mkOption { type = lib.types.bool; default = false; };
          };
        };
        default = {};
        description = "Proxmox-cluster-specific info. Empty for non-Proxmox providers.";
      };
      pool = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "XCP-ng pool info (master host, primary SR/network). Empty for non-XO providers.";
      };
    };
  });

  # Lightweight type for utility providers that carry no endpoint,
  # secrets, state, or cluster info. random/tls/time/cloudinit are
  # config-less (they need only a `required_providers` entry and
  # generate values in-plan). docker carries an optional `endpoint`
  # (daemon host URL) + `secrets` (TLS material) per instance.
  utilityProviderType = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = "Terraform provider source address (e.g. hashicorp/random).";
      };
      version = lib.mkOption {
        type = lib.types.str;
        description = "Version constraint for required_providers.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Daemon/host URL — docker only (e.g. ssh://root@10.40.0.x or tcp://host:2376).";
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Map of provider-config-key → SOPS path (docker TLS certs, etc.).";
      };
    };
  };
in {
  options.fleet.providers = {
    proxmox = lib.mkOption {
      type = lib.types.attrsOf providerInstanceType;
      default = {};
      description = "Proxmox provider instances, keyed by name (e.g. prod, dev).";
    };
    xen-orchestra = lib.mkOption {
      type = lib.types.attrsOf providerInstanceType;
      default = {};
      description = "Xen Orchestra provider instances, keyed by name (e.g. main).";
    };
    cloudflare = lib.mkOption {
      type = lib.types.attrsOf providerInstanceType;
      default = {};
      description = "Cloudflare provider instances, keyed by name (e.g. prod).";
    };
    grafana = lib.mkOption {
      type = lib.types.attrsOf providerInstanceType;
      default = {};
      description = ''
        Grafana provider instances, keyed by name (e.g. cloud). Manages
        Grafana Cloud stack resources: synthetic monitoring checks,
        alerting contact points, notification templates (INFRA-144).
      '';
    };
    proxmox-backup-server = lib.mkOption {
      type = lib.types.attrsOf providerInstanceType;
      default = {};
      description = ''
        Proxmox Backup Server provider instances, keyed by name. Separate
        from `proxmox` because PBS runs on a different daemon (port 8007)
        and uses a different provider (Tinyblargon/proxmox-backup-server).
      '';
    };

    # ─── Utility providers ─────────────────────────────────────────
    # Config-less singletons: only a `required_providers` entry is
    # emitted, no `provider` block. They generate values in-plan that
    # feed other resources + SOPS. null = not declared.
    random = lib.mkOption {
      type = lib.types.nullOr utilityProviderType;
      default = null;
      description = "hashicorp/random — random_password/id/uuid/string/bytes generated in-plan.";
    };
    tls = lib.mkOption {
      type = lib.types.nullOr utilityProviderType;
      default = null;
      description = "hashicorp/tls — private keys, CSRs, self-/locally-signed certs (feeds step-ca).";
    };
    time = lib.mkOption {
      type = lib.types.nullOr utilityProviderType;
      default = null;
      description = "hashicorp/time — time_sleep (post-create waits), time_static/rotating.";
    };
    cloudinit = lib.mkOption {
      type = lib.types.nullOr utilityProviderType;
      default = null;
      description = "hashicorp/cloudinit — renders multipart cloud-config (for dev VMs / Debian first-boot).";
    };
    ansible = lib.mkOption {
      type = lib.types.nullOr utilityProviderType;
      default = null;
      description = ''
        ansible/ansible — runs ansible-playbook from a terraform resource
        (ansible_playbook). Used to chain post-install Ansible against
        compute resources tofu just created, so `sk deploy tf apply` does
        the whole "create the host + converge its config" cycle in one
        shot. The provider runs `ansible-playbook` locally on whoever
        runs tofu, so SSH key + inventory must be reachable there.
      '';
    };

    docker = lib.mkOption {
      type = lib.types.attrsOf utilityProviderType;
      default = {};
      description = ''
        kreuzwerker/docker provider instances, keyed by daemon host.
        Manages docker RESOURCES (containers, images, networks, volumes)
        on a target daemon — NOT the daemon's own config, which stays in
        the host's NixOS module / cloud-init. Each instance's `endpoint`
        is the daemon URL (ssh:// or tcp://).
      '';
    };
  };
}
