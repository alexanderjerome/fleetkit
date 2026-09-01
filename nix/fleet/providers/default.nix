{ lib, ... }:

# Provider & instance registry (schema v2) — schema only.
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
  v2 = import ../v2-types.nix { inherit lib; };

  providerInstanceType = lib.types.submodule ({ name, ... }: {
    options = {
      # ── ADR-096: the provider-rooted resource tree ────────────────
      # Machines and provider-scoped objects may be authored HERE, in
      # place, instead of in the flat fleet.compute / fleet.resources
      # namespaces. v2-normalize.nix lifts everything declared here into
      # those flat options, so every emitter, validator and projection
      # keeps working unchanged — the flat layer is becoming the derived
      # normal form rather than the authoring surface.
      nodes = lib.mkOption {
        type = lib.types.attrsOf v2.nodeType;
        default = {};
        description = "Hypervisor members of this instance, as typed objects (mgmt_ip, placed machines). Complements cluster.nodes (names only); a name present in either counts as a member.";
      };
      resources = lib.mkOption {
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf v2.looseKind;
          options = {
            lxc = lib.mkOption { type = v2.machines; default = {}; description = "Instance-scoped containers (single-node instances; multi-node clusters place under nodes.<n>)."; };
            vm  = lib.mkOption { type = v2.machines; default = {}; description = "Instance-scoped VMs (XO VMs are pool-placed, so they belong here)."; };
          };
        };
        default = {};
        description = "Provider-scoped resources by kind — pools/acls/zones/checks per this provider's kind map (v2-types.nix), plus lxc/vm.";
      };

      source = lib.mkOption {
        type = lib.types.str;
        example = "bpg/proxmox";
        description = "Terraform provider source address (e.g. bpg/proxmox).";
      };
      version = lib.mkOption {
        type = lib.types.str;
        example = "0.66.3";
        description = "Version constraint for required_providers.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://192.0.2.10:8006/";
        description = "API endpoint URL. Optional — provider may derive from secrets.";
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = lib.literalExpression ''{ api_token = "integrations/proxmox/api_token"; }'';
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
          example = "proxmox-dev";
          description = "S3 key prefix for this instance's tfstate(s). Full path: s3://<bucket>/<prefix>/<stack>/terraform.tfstate";
        };
      };
      minVersion = lib.mkOption {
        type = lib.types.str;
        default = "9.0";
        example = "9.0";
        description = "Lowest Proxmox VE major.minor this instance is expected to run. fleetkit's zero-touch NixOS LXC first boot needs PVE 9 (its NixOS LXC setup plugin writes the guest's eth0.network from the container's net0 at create time); `fleet pve status` warns when the live node is older. Informational for non-PVE providers.";
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
            nodes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = [ "pve-alpha" "pve-beta" ];
              description = "Cluster member names. More than one entry makes the instance multi-node, which forces every compute entry on it to set `node` explicitly (validator-enforced).";
            };
            primary_node = lib.mkOption {
              type = lib.types.str;
              default = "";
              example = "pve-alpha";
              description = "Fallback placement target: compute/resource entries that leave `node` empty are provisioned here.";
            };
            node_addresses = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              example = { pve1 = "198.51.100.11"; pve2 = "pve2.mgmt.example.internal"; };
              description = "Node name → SSH host used by out-of-band local-exec steps (fleet.compute.<name>.lxc_extra_conf). A node missing here is reached by its name.";
            };
            ha_manager = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether the cluster runs the PVE HA manager. Informational — not consumed by any emitter yet.";
            };
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
        example = "hashicorp/random";
        description = "Terraform provider source address (e.g. hashicorp/random).";
      };
      version = lib.mkOption {
        type = lib.types.str;
        example = "3.6.2";
        description = "Version constraint for required_providers.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "ssh://root@192.0.2.50";
        description = "Daemon/host URL — docker only (e.g. ssh://root@192.0.2.50 or tcp://host:2376).";
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
      example = lib.literalExpression ''
        {
          dev = {
            source = "bpg/proxmox";
            version = "0.66.3";
            endpoint = "https://192.0.2.10:8006/";
            secrets.api_token = "integrations/proxmox/api_token";
            state.prefix = "proxmox-dev";
            cluster.primary_node = "pve";
          };
        }
      '';
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
        compute resources tofu just created, so `fleet deploy tf apply` does
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
