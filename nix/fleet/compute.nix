{ lib, ... }:

# Schema for fleet.compute — OS-carrying resources (LXC containers + KVM VMs).
# This file only declares the type and the `options.fleet.compute`
# mkOption. Per-host *entries* live next to their NixOS module in
# nix/hosts/**/<name>.nix.
#
# Per-resource attributes:
#   env                 logical env label (infra / platform / dev / prod / ...)
#   stack               dot-path for grouping (e.g. "bitcoin.mainnet")
#   provider_instance   "<provider>.<instance>" pointer into fleet.providers
#   kind                "container" (LXC) | "vm" (KVM/QEMU)
#   vm_id               Proxmox VMID — unique within (provider_instance, kind)
#   name                Hostname of the machine (defaults to the attrset key).
#                       Use when the operational hostname differs from the
#                       fleet key — e.g. tier-1 PVE hosts where the key is
#                       `pve-data` but the hostname is `data.example.pve`.
#   tags                free-form tags; STATEFUL_TAGS trigger protect requirement
#   ip, internal_ip     network addressing
#   cpu_cores, memory_mb, swap_mb, root_disk_gb, root_disk_datastore
#   mount_points        list of { datastore, path, size, backup } (LXC only)
#   features            { nesting, fuse, keyctl } (LXC only)
#   network_mode        "single-internal" | "single-external" | "dual" | "custom-netgate" | "custom-btc-testnet" | "custom-vm" | "lxc-router"
#   protect             bool — emits lifecycle.prevent_destroy = true
#   ignore_changes      list of TF attribute paths to ignore drift on
#   notes               free-text audit note. Plain-string fallback;
#                       rendered in the PVE Notes panel (Summary tab)
#                       when `note` is null.
#   note                structured Notes content (templates/proxmox →
#                       mkNote). Renders to markdown and overrides
#                       `notes` when set.
#   pool                pool_id of a fleet.resources pool entry; null = no pool
#   ssh_groups          Authentik groups permitted to SSH (layer 2 of the
#                       three-layer access model — see fleet/access.nix
#                       for the layer-3 web/OIDC equivalent).
#
# Stateful-tag-bearing resources must carry protect = true OR live on
# a provider_instance with destruction_policy = "strict" (validator enforces).

let
  # ── Shared option types — one ComputeResource shape ─────────────
  mountPointOpts = lib.types.submodule {
    options = {
      datastore = lib.mkOption { type = lib.types.str; description = "PVE storage the mount-point volume is allocated on (e.g. \"local-storage\")."; };
      path = lib.mkOption { type = lib.types.str; description = "Mountpoint inside the container (e.g. \"/data\")."; };
      size = lib.mkOption { type = lib.types.str; description = ''Size like "256G". Stringly-typed to match bpg input.''; };
      backup = lib.mkOption { type = lib.types.bool; default = true; description = "Include this volume in vzdump backups."; };
    };
  };
  featuresOpts = lib.types.submodule {
    options = {
      nesting = lib.mkOption { type = lib.types.bool; default = true; description = "Allow nested containers/namespaces inside the LXC (PVE `nesting` feature; needed for systemd-nspawn, Docker, nix sandboxed builds)."; };
      fuse = lib.mkOption { type = lib.types.bool; default = true; description = "Allow FUSE filesystem mounts inside the LXC (PVE `fuse` feature)."; };
      keyctl = lib.mkOption { type = lib.types.bool; default = true; description = "Allow the keyctl() syscall inside the LXC (PVE `keyctl` feature; needed by systemd-based guests)."; };
    };
  };
  importOpts = lib.types.submodule {
    options = {
      from_uuid = lib.mkOption { type = lib.types.str; default = ""; description = "XO VM UUID for cross-provider imports (e.g. pve-prod)."; };
    };
  };
  cloudInitUserOpts = lib.types.submodule {
    options = {
      ref = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Registry key into fleet.access.users.";
      };
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Username (inline mode; ignored when ref is set).";
      };
      ssh_keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "SSH keys (inline mode; ignored when ref is set).";
      };
      sudo = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Grant passwordless sudo on this VM.";
      };
      extra_groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Linux groups added on this VM (e.g. \"docker\"). Independent of LDAP groups in fleet.access.users.";
      };
    };
  };
  cloudInitWriteFileOpts = lib.types.submodule {
    options = {
      path = lib.mkOption { type = lib.types.str; description = "Absolute destination path of the file inside the guest."; };
      permissions = lib.mkOption { type = lib.types.str; default = "0644"; description = "Octal file mode string passed to cloud-init write_files."; };
      owner = lib.mkOption { type = lib.types.str; default = "root:root"; description = "\"user:group\" ownership passed to cloud-init write_files."; };
      content = lib.mkOption { type = lib.types.str; description = "Literal file contents, embedded verbatim in the cloud-init user-data."; };
    };
  };
  cloudInitOpts = lib.types.submodule {
    options = {
      users = lib.mkOption {
        type = lib.types.listOf cloudInitUserOpts;
        default = [];
        example = lib.literalExpression ''
          [ { ref = "alice"; extra_groups = [ "docker" ]; } ]
        '';
        description = "Local users created by cloud-init's `users:` directive.";
      };
      write_files = lib.mkOption {
        type = lib.types.listOf cloudInitWriteFileOpts;
        default = [];
        description = "Files written to the VM filesystem before runcmd runs.";
      };
      install_nix = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "If true, append a Determinate Nix install command to cloud-init runcmd.";
      };
      runcmd = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra runcmd lines appended after install_nix. YAML quoting is the caller's responsibility.";
      };
      hostname = lib.mkOption { type = lib.types.str; default = ""; description = "Override hostname (defaults to fleet.compute key)."; };
      vyos_config_commands = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          VyOS-specific cloud-init: a list of VyOS configuration tree
          commands (e.g. "set system host-name 'router'"). When non-empty,
          renders as a top-level `vyos_config_commands:` block in the
          user-data — VyOS's cloud-init module reads this and applies the
          commands at first boot inside a config transaction (load → set
          → commit → save). Non-VyOS substrates ignore the block. Used
          to bootstrap hostname, HTTPS API + token, base interface IPs,
          and SSH on a fresh VyOS install so the Terraform provider can
          take over from there.
        '';
      };
    };
  };
  dataDiskOpts = lib.types.submodule {
    options = {
      size_gb = lib.mkOption { type = lib.types.int; description = "Disk size in GiB."; };
      mount_path = lib.mkOption { type = lib.types.str; description = "Mountpoint (e.g. /data)."; };
      filesystem = lib.mkOption { type = lib.types.str; default = "ext4"; description = "Filesystem to format with on first boot."; };
      datastore_id = lib.mkOption { type = lib.types.str; default = "local-storage"; description = "PVE storage to allocate the disk on."; };
    };
  };

  linkOpts = lib.types.submodule {
    options = {
      text = lib.mkOption { type = lib.types.str; description = "Link label as rendered in the Notes markdown."; };
      url  = lib.mkOption { type = lib.types.str; description = "Link target URL."; };
    };
  };
  serviceLineOpts = lib.types.submodule {
    options = {
      name    = lib.mkOption { type = lib.types.str; description = "Service name shown in the Notes services table."; };
      address = lib.mkOption { type = lib.types.str; default = ""; description = "Address/URL the service is reachable at. Empty = omitted from the rendered line."; };
      port    = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; description = "Service port. null = omitted from the rendered line."; };
    };
  };
  noteOpts = lib.types.submodule {
    options = {
      title    = lib.mkOption { type = lib.types.str; default = ""; description = "Heading of the rendered Notes markdown. Empty = falls back to the host name."; };
      summary  = lib.mkOption { type = lib.types.str; default = ""; description = "One-paragraph description rendered under the title."; };
      services = lib.mkOption { type = lib.types.listOf serviceLineOpts; default = []; description = "Services running on the host, rendered as a bullet list (name, address, port)."; };
      links    = lib.mkOption { type = lib.types.listOf linkOpts; default = []; description = "Related links (dashboards, runbooks, tickets) rendered as a bullet list."; };
      stateful = lib.mkOption { type = lib.types.bool; default = false; description = "Render the STATEFUL/protected warning banner in the Notes panel. Informational only — destruction protection itself comes from `protect` / STATEFUL_TAGS."; };
      extra    = lib.mkOption { type = lib.types.str; default = ""; description = "Free-form markdown appended last."; };
    };
  };

  computeResourceType = lib.types.submodule ({ name, ... }: {
    options = {
      env = lib.mkOption { type = lib.types.str; example = "platform"; description = "Logical env (infra / platform / dev / prod / ...)."; };
      stack = lib.mkOption { type = lib.types.str; example = "bitcoin.mainnet"; description = "Dot-path stack label within env."; };
      provider_instance = lib.mkOption {
        type = lib.types.strMatching "^[a-z-]+\\.[a-z][a-z0-9-]*$";
        example = "proxmox.dev";
        description = ''Pointer to fleet.providers: "<provider>.<instance>" (e.g. "proxmox.dev").'';
      };
      kind = lib.mkOption {
        type = lib.types.enum [ "container" "vm" ];
        description = "LXC container or KVM VM.";
      };

      # Identity
      vm_id = lib.mkOption { type = lib.types.int; description = "Proxmox VMID."; };

      # Operational hostname (defaults to the attrset key). Used when the
      # fleet key and the canonical hostname diverge — e.g. tier-1 PVE
      # hosts where the fleet key is `pve-data` but the actual hostname
      # is `data.example.pve`. Domain conventions:
      #   *.dev — internal-to-proxmox, not public
      #   *.io  — public-facing
      #   *.pve — internal certs (issued by netcore ACME for in-proxmox
      #           hosts and services that don't need public certification)
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Hostname for the machine (defaults to the fleet attrset key).";
      };

      cloneFrom = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "If non-null, clone from this source VMID at provision time.";
      };

      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "postgres" "monitoring" ];
        description = "Free-form tags (shown in the PVE UI, usable as Colmena deploy targets). Tags listed in fleet.STATEFUL_TAGS additionally force destruction protection (validator-enforced).";
      };
      ip = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "198.51.100.20";
        description = "External/LAN IPv4 address (bare, no prefix — the emitter appends the prefix length). Used by the external leg of the dual / single-external / custom network modes. Empty when the host has no external interface.";
      };
      internal_ip = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "192.0.2.104";
        description = "Internal fleet-LAN IPv4 address (bare, no prefix). Statically configured into the guest at create time and used as the host's inventory/SSH address (hosts.json, DNS A records). Empty for hosts without an internal interface (e.g. DHCP'd XCP-ng VMs).";
      };

      pool = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''Pool membership — pool_id of a fleet.resources pool entry.'';
      };

      # Which PVE cluster member this resource lands on. Single-node
      # clusters can leave this empty — the emitter falls back to
      # fleet.providers.<instance>.cluster.primary_node. Multi-node
      # clusters MUST set it explicitly; the validator (nix/fleet/
      # default.nix) throws if any compute entry on a multi-node
      # cluster has no node specified.
      #
      # bpg/proxmox takes a single API endpoint per cluster and forwards
      # internally between members; this field just tells the provider
      # where to provision. Not used by XCP-ng/XOA emitters (`xoa.pool_ref`
      # serves the equivalent role there).
      node = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "PVE cluster member name (e.g. \"pve-data\"). Empty = defaults to provider's cluster.primary_node.";
      };

      ssh_groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "platform-admins" ];
        description = "Authentik groups allowed SSH access (sssd simple_allow_groups).";
      };

      sudo_groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Authentik groups granted password-required sudo on this host
          (sssd → security.sudo.extraRules). In practice a subset of
          ssh_groups (you cannot sudo on a host you cannot log into).
          Empty = no LDAP user gets sudo here; local wheel accounts
          (core.nix) are unaffected. See ADR-028.
        '';
      };

      protect = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Emit `lifecycle.prevent_destroy = true` on the generated Terraform resource. Required (or a strict-destruction-policy provider) for entries carrying a fleet.STATEFUL_TAGS tag; `fleet tf destroy` refuses to target protected resources.";
      };
      ignore_changes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Terraform attribute paths emitted into `lifecycle.ignore_changes` — drift on these attributes is ignored at plan time.";
      };

      # Lifecycle gate. When false, the entry is filtered out before
      # the validator runs and before any emitter sees it — net effect
      # equivalent to commenting the file out, but the declaration
      # stays version-controlled so we can flip it back on without
      # re-typing it. Designed for "build-on-demand" workloads like
      # the XCP-ng template bootstrap installer: declared in fleet so
      # the IaC trail is honest, but only provisioned when explicitly
      # flipped to true. Default true preserves behaviour for every
      # existing entry.
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Toggle for build-on-demand entries. When false, the entry is
          filtered out before validation + emission, so `sk deploy tf
          apply <stack>` neither provisions nor preserves it. Flip to
          true to materialise; flip back to false (and apply) to
          destroy. See nix/hosts/xoa/xo-installer-v10.nix for the
          canonical pattern.
        '';
      };

      # Who creates/destroys the machine. "managed" (default) = this
      # repo's terranix/tofu pipeline; the entry lands in a fleet.stack
      # and is provisioned by `sk deploy tf apply`. "external" = the
      # machine exists outside this repo's providers (e.g. the homelab
      # dev server, INFRA-170 / ADR-080): the entry still feeds
      # hostsJson (Colmena target, `sk remote`, `sk inventory`) but is
      # excluded from fleet.stacks (no Terraform emitted) and from the
      # provider-coupled validators. `provider_instance` remains
      # required as a descriptive label (e.g. "external.homelab") so
      # vm_id uniqueness stays scoped per substrate; it does NOT need a
      # fleet.providers entry when provisioning = "external".
      provisioning = lib.mkOption {
        type = lib.types.enum [ "managed" "external" ];
        default = "managed";
        description = "\"managed\" = terranix/tofu-provisioned by this repo; \"external\" = provisioned elsewhere, NixOS-managed only.";
      };

      notes = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Free-text audit note. Plain-string fallback rendered in the PVE Notes panel (Summary tab) when the structured `note` is null.";
      };
      note = lib.mkOption {
        type = lib.types.nullOr noteOpts;
        default = null;
        description = "Structured PVE Notes content. Takes precedence over `notes` when set.";
      };

      cpu_cores = lib.mkOption { type = lib.types.int; default = 2; description = "Number of CPU cores allocated to the guest."; };
      memory_mb = lib.mkOption { type = lib.types.int; default = 2048; description = "RAM in MiB. LXC containers pick up changes without a restart; VMs need a reboot."; };
      swap_mb = lib.mkOption { type = lib.types.int; default = 2048; description = "Swap in MiB (LXC only)."; };
      root_disk_gb = lib.mkOption { type = lib.types.int; default = 16; description = "Root disk size in GiB."; };
      root_disk_datastore = lib.mkOption { type = lib.types.str; default = "local-storage"; description = "PVE storage the root disk is allocated on."; };

      mount_points = lib.mkOption {
        type = lib.types.listOf mountPointOpts;
        default = [];
        example = lib.literalExpression ''
          [ { datastore = "local-storage"; path = "/data"; size = "64G"; } ]
        '';
        description = "Extra PVE mount-point volumes ({ datastore, path, size, backup }) attached to the container (LXC only).";
      };
      features = lib.mkOption {
        type = featuresOpts;
        default = {};
        description = "PVE container feature flags ({ nesting, fuse, keyctl }, all default true; LXC only).";
      };

      network_mode = lib.mkOption {
        type = lib.types.enum [ "single-internal" "single-external" "dual" "custom-netgate" "custom-btc-testnet" "custom-vm" "lxc-router" ];
        default = "single-internal";
        description = "Which NIC/bridge layout the emitter generates: single-internal (one NIC on the internal bridge), single-external (one NIC on the LAN bridge), dual (both), or one of the custom/special-case layouts.";
      };

      privileged = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run this LXC in privileged mode (sets `unprivileged = false` in the Proxmox container). Only needed for hosts that run NAT or other kernel-capability-sensitive workloads.";
      };

      host_managed = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override bpg-provider network_interface.host_managed for this host. null = use provider default (host_managed=0). true = let PVE configure the in-container interface from ip_config (legacy / bootstrap-friendly).";
      };

      mac_address_eth0 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pin the eth0 MAC address (uppercase colon-separated, e.g. \"BC:24:11:5B:EA:26\"). null = bpg-provider auto-assigns. Currently honoured by `lxc-router` mode; extend the network-mode emitters as needed for other modes.";
      };

      internal_bridge = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "vmbr2";
        description = "Bridge the legacy `single-internal` mode attaches eth0 to. null = vmbr1, or vmbr0 when the provider instance is listed in fleet.settings.providers.proxmox.singleBridgeInstances. (Declared-mode hosts set the bridge per interface instead.)";
      };

      import = lib.mkOption {
        type = importOpts;
        default = {};
        description = "Cross-provider import settings ({ from_uuid }). Set from_uuid to adopt an existing XO VM instead of creating a fresh one.";
      };
      cloud_init = lib.mkOption {
        type = cloudInitOpts;
        default = {};
        description = "Cloud-init user-data for VM guests (users, write_files, runcmd, hostname, VyOS config commands). Ignored for entries that don't render cloud-init (e.g. LXC containers).";
      };

      vm_template = lib.mkOption {
        type = lib.types.enum [ "nixos" "debian-13" ];
        default = "debian-13";
        description = ''Legacy: "nixos" clones VMID 9000, "debian-13" imports the prepared Debian qcow2 (ADR-013/018). Prefer `image` for new entries.'';
      };

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''Explicit VM image. "file:<file_id>" imports a qcow2; "clone:<vmid>" clones a template.'';
      };

      ansible_playbook = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Override the Ansible playbook the terranix `ansible_playbook`
          emitter chains to this host after provisioning. By convention
          the framework playbooks apply (non-NixOS containers →
          fleetkit's ansible/playbooks/developer.yml, VMs tagged
          "pve-host" → ansible/playbooks/pve.yml); set this to a path
          string (absolute, or relative to the tofu working dir
          .tf/<stack>/) to substitute a consumer playbook instead.
          Consumer playbooks resolve roles via ANSIBLE_ROLES_PATH, which
          the fleet CLI points at both the consumer's ansible/roles and
          the framework tree. Only consulted for hosts the emitter's
          conventions already match — it does not opt additional hosts
          into Ansible.
        '';
      };

      data_disks = lib.mkOption {
        type = lib.types.listOf dataDiskOpts;
        default = [];
        example = lib.literalExpression ''
          [ { size_gb = 100; mount_path = "/data"; } ]
        '';
        description = "Additional virtio data disks. Emitted as virtio1, virtio2, ... and formatted/mounted by cloud-init.";
      };

      xoa = lib.mkOption {
        default = {};
        description = "XCP-ng/XOA-specific compute config. Active when provider_instance starts with xen-orchestra.";
        type = lib.types.submodule {
          options = {
            template = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Full fleet.resources key for the source template (e.g. \"xo-template-nixos\"). Required for kind=vm on XOA.";
            };
            pool_ref = lib.mkOption {
              type = lib.types.str;
              default = "xo-pool-main";
              description = "Full fleet.resources key for the target XCP-ng pool (e.g. \"xo-pool-main\").";
            };
            networks = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  ref = lib.mkOption {
                    type = lib.types.str;
                    description = "Full fleet.resources key for the network (e.g. \"xo-network-wan\").";
                  };
                  mac = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Pin MAC address; null = XCP-ng assigns one.";
                  };
                };
              });
              default = [];
              description = "Ordered NIC list. First entry becomes eth0 inside the guest.";
            };
            disks = lib.mkOption {
              type = lib.types.listOf (lib.types.submodule {
                options = {
                  sr_ref  = lib.mkOption {
                    type = lib.types.str;
                    description = "Full fleet.resources key for the SR (e.g. \"xo-sr-main\").";
                  };
                  name    = lib.mkOption { type = lib.types.str; description = "VDI name label as shown in Xen Orchestra."; };
                  size_gb = lib.mkOption {
                    type = lib.types.int;
                    description = ''
                      BASE size in GiB — what terranix provisions at CREATE
                      time. ForceNew in the vatesfr/xenorchestra provider;
                      ignored for drift afterwards (mkXoLifecycle). Do NOT
                      bump this to grow a live disk — use size_add_gb.
                    '';
                  };
                  size_add_gb = lib.mkOption {
                    type = lib.types.int;
                    default = 0;
                    description = ''
                      Additional GiB layered on top of size_gb, applied
                      IMPERATIVELY by `xoa-cli reconcile-disks` (never by
                      terraform — INFRA-172 / ADR-081). Live target =
                      size_gb + size_add_gb; the reconciler grows the VDI
                      when live < target and never shrinks. Grow a disk by
                      editing this field and running the reconciler.
                    '';
                  };
                };
              });
              default = [];
              description = "Additional VDIs beyond the cloned template root disk.";
            };
            iso_ref = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Optional fleet.resources key for an ISO to attach as a CDROM
                (e.g. "xo-iso-nixos-minimal"). When set, the VM is created
                with the ISO pre-attached and the underlying VM's boot order
                ("dc" — CD then disk in XOA's UEFI default) makes it boot
                from the ISO on first power-on. Used for one-shot OS installs
                onto blank disks. After install, eject via `xo-cli vm.ejectCd`
                and the VM boots from disk on next start.
              '';
            };
            cloud_network_config = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Cloud-init network-config (v2 YAML) passed verbatim to
                xenorchestra_vm.cloud_network_config. Only meaningful for
                cloud-init guests (non-NixOS); use `match: {macaddress: ...}`
                stanzas against pinned xoa.networks[*].mac so the config is
                immune to guest interface naming (eth0 vs enX0 on Xen).
                NixOS VMs leave this null — networkd owns their config.
                (INFRA-194; also the path INFRA-174's Ubuntu dev box needs.)
              '';
            };
          };
        };
      };
    };
  });

in {
  options.fleet.compute = lib.mkOption {
    type = lib.types.attrsOf computeResourceType;
    default = {};
    example = lib.literalExpression ''
      {
        app-db = {
          env = "platform";
          stack = "core";
          provider_instance = "proxmox.dev";
          kind = "container";
          vm_id = 204;
          internal_ip = "192.0.2.104";
          cpu_cores = 4;
          memory_mb = 8192;
          tags = [ "postgres" ];
          protect = true;
          mount_points = [
            { datastore = "local-storage"; path = "/data"; size = "64G"; }
          ];
        };
      }
    '';
    description = "Every LXC/VM across all providers and envs. Entries live in nix/hosts/**/<name>.nix.";
  };
}
