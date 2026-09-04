{ config, lib, pkgs ? null }:

# Emitters that translate a single fleet entry into a bpg/proxmox
# resource block. Consumed by nix/tf/compute/proxmox.nix (for
# LXC + KVM) and nix/tf/resources/proxmox.nix (for everything
# else — bridges, pools, ACLs, realms, DNS, downloads, files,
# cluster-options).

let
  net = config.fleet.network;

  # Gateways are optional (null ⇒ isolated/minimal fleet): omit the
  # gateway attr from ip_config instead of emitting null.
  optGw = gw: lib.optionalAttrs (gw != null) { gateway = gw; };

  # Bare address → CIDR with the fleet-wide prefix length
  # (fleet.network.internal_prefix_len / lan_prefix_len, default 24 —
  # what used to be a literal "/24" here).
  ipv4Cidr = ip: len: "${ip}/${toString len}";
  internalCidr = ip: ipv4Cidr ip net.internal_prefix_len;
  lanCidr = ip: ipv4Cidr ip net.lan_prefix_len;

  # Note renderers (markdown → bpg `description`).
  notes = import ../notes/proxmox { inherit lib; };

  # Resolve which PVE cluster member a given resource lands on.
  # bpg/proxmox takes one provider per cluster and forwards API
  # calls between members; node_name is REQUIRED on every resource
  # to tell the provider where to provision.
  #
  # Precedence:
  #   1. meta.node — explicit per-resource (mandatory on multi-node
  #      clusters; validator in nix/fleet/default.nix enforces).
  #   2. fleet.providers.proxmox.<instance>.cluster.primary_node —
  #      single-node clusters and provider default fall through here.
  resolveNode = meta:
    let
      parts = lib.strings.splitString "." meta.provider_instance;
      inst = builtins.elemAt parts 1;
      providerCfg = config.fleet.providers.proxmox.${inst} or null;
      explicit = meta.node or "";
      fallback = if providerCfg == null then "" else providerCfg.cluster.primary_node;
    in
      if explicit != "" then explicit else fallback;

  # Picks the right description string for an LXC/VM:
  #   - structured `note` (rendered via mkNote) wins,
  #   - else the legacy `notes` string is used as plain markdown,
  #   - else nothing is emitted.
  computeDescription = meta:
    if meta.note or null != null then notes.mkNote meta.note
    else if meta.notes or "" != "" then meta.notes
    else null;

  # Network-mode dispatch — reproduces the Python Declarer logic.
  # Every initialization block carries the cluster-wide DNS list
  # (fleet.network.dns_servers — fleet DNS first, public fallback) so
  # fresh LXCs and VMs boot resolvable even when the fleet's own DNS
  # isn't up yet. mkVm has its own initialization block and adds
  # DNS there directly; LXCs (mkContainer) rely entirely on mkNetwork.
  # Create-time DNS block: per-guest override (meta.dns) falling back to
  # the cluster-wide fleet.network values. dns_domain is optional (null ⇒
  # no internal zone): omit the attr so the provider writes no search
  # domain into the guest; "" on the per-guest override means the same.
  dnsFor = meta:
    let
      d = meta.dns or { servers = null; domain = null; };
      servers = if d.servers != null then d.servers else net.dns_servers;
      domain = if d.domain != null then d.domain else net.dns_domain;
    in { inherit servers; }
       // lib.optionalAttrs (domain != null && domain != "") { inherit domain; };

  # Lifecycle attributes shared by containers and VMs; each emitted only
  # when it differs from what the emitter produced before the option
  # existed (protection off, startup unmanaged).
  lifecycleAttrs = meta:
    lib.optionalAttrs (meta.protection or false) { protection = true; }
    // lib.optionalAttrs ((meta.startup or null) != null) {
      startup = lib.filterAttrs (_: v: v != null) {
        inherit (meta.startup) order up_delay down_delay;
      };
    };

  mkNetwork = meta: let
    mode = meta.network_mode;
    dnsConfig = dnsFor meta;
    # Per-host override for bpg-provider's `host_managed` attribute. Splice
    # into every network_interface entry when set. null = leave bpg default.
    hmAttrs = if (meta ? host_managed && meta.host_managed != null)
      then { host_managed = meta.host_managed; }
      else { };
    nic = base: base // hmAttrs;

    # Internal-LAN bridge name depends on which PVE cluster we're
    # emitting for. The common shape puts the internal LAN on vmbr1
    # (the host's vmbr0 carries the WAN-side address). Clusters whose
    # PVE nodes have a single NIC carrying internal traffic directly
    # on vmbr0 (e.g. PVE-on-XCP-ng VMs) are listed in
    # fleet.settings.providers.proxmox.singleBridgeInstances — any
    # LXC on those clusters uses vmbr0 for "internal".
    #
    # Dispatch on the provider_instance name; per-host
    # `internal_bridge` override wins when set.
    internalBridgeDefault =
      let parts = lib.strings.splitString "." meta.provider_instance;
          inst  = builtins.elemAt parts 1;
      in if builtins.elem inst config.fleet.settings.providers.proxmox.singleBridgeInstances
         then "vmbr0" else "vmbr1";
    internalBridge =
      if (meta ? internal_bridge && meta.internal_bridge != null && meta.internal_bridge != "")
      then meta.internal_bridge
      else internalBridgeDefault;
  in
    if mode == "single-internal" then {
      network_interface = [(nic { name = "eth0"; bridge = internalBridge; })];
      initialization = {
        hostname = meta._name;
        dns = dnsConfig;
        ip_config = [{
          ipv4 = { address = internalCidr meta.internal_ip; } // optGw net.gateway;
        }];
      };
    }
    # Mirror of single-internal but on vmbr0 with the LAN gateway
    # (fleet.network.lan_gateway). Used for hosts that should live only
    # on the LAN (no vmbr1 NIC, no internal_ip). The fleet's internal
    # DNS / service-alias mesh won't reach the host directly; public
    # ingress is expected to be a LAN-router port-forward straight to
    # `meta.ip`.
    else if mode == "single-external" then {
      network_interface = [(nic { name = "eth0"; bridge = "vmbr0"; })];
      initialization = {
        hostname = meta._name;
        dns = dnsConfig;
        ip_config = [{
          ipv4 = { address = lanCidr meta.ip; } // optGw net.lan_gateway;
        }];
      };
    }
    else if mode == "dual" then {
      network_interface = [
        (nic { name = "eth0"; bridge = "vmbr0"; })
        (nic { name = "eth1"; bridge = "vmbr1"; })
      ];
      initialization = {
        hostname = meta._name;
        dns = dnsConfig;
        ip_config = [{ ipv4 = { address = internalCidr meta.internal_ip; }; }];
      };
    }
    else if mode == "custom-netgate" then {
      network_interface = [
        (nic { name = "eth0"; bridge = "vmbr0"; mac_address = "BC:24:11:5B:EA:26"; })
        (nic { name = "eth1"; bridge = "vmbr1"; })
      ];
      initialization = {
        hostname = "netgate";
        dns = dnsConfig;
        ip_config = [
          { ipv4 = { address = lanCidr meta.ip; } // optGw net.lan_gateway; }
          # netgate IS the vmbr1 gateway — no upstream here.
          { ipv4 = { address = internalCidr meta.internal_ip; }; }
        ];
      };
    }
    else if mode == "custom-btc-testnet" then {
      network_interface = [(nic { name = "eth0"; bridge = "vmbr1"; })];
      initialization = {
        hostname = meta._name;
        dns = dnsConfig;
        ip_config = [{
          ipv4 = { address = internalCidr meta.internal_ip; } // optGw net.gateway;
          ipv6 = { address = "auto"; };
        }];
      };
    }
    # ADR-021: dual-NIC LXC that IS a LAN gateway. eth0/vmbr0 carries
    # the WAN-side address + default route (fleet.network.lan_gateway);
    # eth1/vmbr1 carries the LAN-side address with no gateway (this host
    # IS the gateway for LAN-only containers). Used by the `router` LXC;
    # only works on privileged containers because NAT needs CAP_NET_ADMIN.
    # If meta.mac_address_eth0 is set, pins the WAN NIC's MAC — needed
    # for ingress so LAN-router port-forwards keep landing across recreates.
    else if mode == "lxc-router" then {
      network_interface = [
        (nic ({ name = "eth0"; bridge = "vmbr0"; }
          // lib.optionalAttrs (meta ? mac_address_eth0 && meta.mac_address_eth0 != null)
               { mac_address = meta.mac_address_eth0; }))
        (nic { name = "eth1"; bridge = "vmbr1"; })
      ];
      initialization = {
        hostname = meta._name;
        dns = dnsConfig;
        ip_config = [
          { ipv4 = { address = lanCidr meta.ip; } // optGw net.lan_gateway; }
          { ipv4 = { address = internalCidr meta.internal_ip; }; }
        ];
      };
    }
    else throw "mkNetwork: unsupported network_mode ${mode} for ${meta._name}";

  # Resolve the provider alias — every TF resource gets
  # `provider = "proxmox.<instance>"` via `provider` attribute.
  mkProviderRef = providerInstance: providerInstance;

  # Destruction-policy-aware lifecycle block.
  mkLifecycle = meta: let
    parts = lib.strings.splitString "." meta.provider_instance;
    inst = builtins.elemAt parts 1;
    instCfg = config.fleet.providers.proxmox.${inst} or null;
    policy = if instCfg == null then "standard" else instCfg.destruction_policy;
    effectiveProtect = meta.protect
      || policy == "strict"
      || (meta ? tags
          && lib.intersectLists meta.tags config.fleet.STATEFUL_TAGS != []
          && policy != "permissive");
    hasIgnore = (meta.ignore_changes or []) != [];
  in
    lib.optionalAttrs (effectiveProtect || hasIgnore) {
      lifecycle = [(lib.mkMerge [
        (lib.optionalAttrs effectiveProtect { prevent_destroy = true; })
        (lib.optionalAttrs hasIgnore { ignore_changes = meta.ignore_changes; })
      ])];
    };

  # Cluster-wide NFS storage `nix-store` (nix-builder tier-0 VM exports
  # /data/nfs/store; registered via ansible proxmox/pve nfs-storage.yml,
  # 2026-06-11). Templates upload once and every cluster node sees them
  # — replaces the old scp-to-every-node bootstrap. (The 2026-06-06
  # attempt failed because nix-builder was then a PVE LXC that couldn't
  # run kernel nfsd; it's since moved to a tier-0 XCP-ng VM.)
  nixosLxcTemplate = "nix-store:vztmpl/nixos-lxc-template-x86_64.tar.xz";
  # The Debian *VM* path (debian13DiskId / debianCloudImage qcow2) was removed
  # (INFRA-137): the fleet has no KVM Debian guests — every non-NixOS guest is a
  # Debian LXC, which uses a vztmpl rootfs tarball (not a VM qcow2). That
  # template should be served cluster-wide from the `nix-store` NFS SR, not a
  # per-node `local:` upload.

  # NixOS LXC template (ADR-021 follow-up). Built from
  # nix/images/by-platform/proxmox.nix via a thin wrapper that gives the
  # tarball a stable name. Replaces the previous manual upload workflow.
  preparedNixosLxcTemplatePath =
    if pkgs != null
    then "${pkgs.callPackage ../../images/lxc-template {
      sshPubKey = config.fleet.network.sysadmin_ssh_key;
    }}/nixos-lxc-template.tar.xz"
    else null;

in rec {
  inherit mkNetwork mkLifecycle mkProviderRef nixosLxcTemplate net;

  # ── LXC container emitter ─────────────────────────────────────
  # When `meta.cloneFrom != null`, the container is provisioned by cloning
  # the named source VMID via the bpg/proxmox provider's `clone` block;
  # `clone` and `operating_system`/`template_file_id` are mutually
  # exclusive in the provider, so the OS template block is dropped on the
  # clone path. Mount points are explicitly re-declared either way so the
  # provider tracks them in state (the source's mounts are inherited at
  # clone time, but tofu still needs them in the resource attrs to detect
  # drift).
  mkContainer = name: meta:
    let
      isClone = meta.cloneFrom != null;
      # New: meta.image, when set on a container, overrides the default
      # NixOS LXC template. Used for non-NixOS LXCs (Debian developer
      # workstations, etc.) — pass the full vztmpl ref like
      # "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst".
      hasCustomImage = (meta.image or null) != null && !isClone;
      lxcTemplateFile =
        if hasCustomImage then meta.image
        else nixosLxcTemplate;
      # Our NixOS LXC template → ostype "nixos" (INFRA-86). PVE 9 ships a
      # NixOS LXC setup plugin (PVE::LXC::Setup::NixOS) whose setup_network
      # writes a static /etc/systemd/network/eth0.network from the net0
      # ip=/gw= at create time — so a fresh container comes up on its
      # declared internal_ip with no `sk bootstraps container` step. (Was
      # "unmanaged", under which PVE wrote no network config and the CT
      # fell back to DHCP.) Custom Debian/Ubuntu images keep their own
      # ostype; any other custom image stays "unmanaged".
      lxcOsType =
        if !hasCustomImage then "nixos"
        else if lib.hasInfix "debian" lxcTemplateFile then "debian"
        else if lib.hasInfix "ubuntu" lxcTemplateFile then "ubuntu"
        else "unmanaged";
      sourceConfig =
        if isClone then {
          clone = { vm_id = meta.cloneFrom; };
        } else {
          operating_system = {
            template_file_id = lxcTemplateFile;
            type = lxcOsType;
          };
        };
      # NixOS LXC templates already bake in the sysadmin SSH key via
      # nix/modules/infra/base/core/default.nix. Debian/Ubuntu templates don't —
      # inject via initialization.user_account so the operator can SSH
      # in immediately after first boot. Hostname is also set so the
      # LXC reports its name to DHCP / chrony / etc.
      initConfig = lib.optionalAttrs hasCustomImage {
        initialization = {
          hostname = name;
          user_account = {
            keys = [ config.fleet.network.sysadmin_ssh_key ];
          };
        };
      };
      # bpg/proxmox creates a fresh empty volume when mount_point omits an
      # explicit volume reference. For cloned containers the data already
      # arrives via the clone, so re-declaring mount_point here would either
      # spawn a second empty disk (current behavior) or fight the cloned
      # one. Skip it on the clone path; declare the cloned mount via
      # ignore_changes so tofu doesn't try to reconcile.
      mountConfig =
        if isClone then {}
        else {
          mount_point = map (mp: {
            volume = mp.datastore;
            path = mp.path;
            size = mp.size;
            backup = mp.backup;
          }) meta.mount_points;
        };
      # ADR-047 moved the LXC template local: → nix-store:. For an EXISTING
      # container the `operating_system.template_file_id` is IMMUTABLE (the
      # creation template can't change without recreating the CT), so tofu reads
      # the new value as drift and ForceNew-replaces every template-path
      # container — blocked fleet-wide by prevent_destroy (was: "Instance cannot
      # be destroyed"). Ignore the whole operating_system block so applies stop
      # trying to destroy+recreate live containers. CREATE is unaffected (a fresh
      # CT still uses the current nix-store template); clones have no such block.
      lifecycleMeta =
        if isClone then meta
        else meta // { ignore_changes = (meta.ignore_changes or []) ++ [ "operating_system" ]; };
    in {
      provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
      node_name = resolveNode meta;
      vm_id = meta.vm_id;
      started = meta.start_on_create;
      start_on_boot = meta.onboot;
      unprivileged = !meta.privileged;
      tags = meta.tags;

      cpu = { cores = meta.cpu_cores; }
        // lib.optionalAttrs (meta.arch != "amd64") { architecture = meta.arch; };
      memory = { dedicated = meta.memory_mb; swap = meta.swap_mb; };
      disk = { datastore_id = meta.root_disk_datastore; size = meta.root_disk_gb; };
      # Only emit fuse/keyctl/mknod/mount when on: a non-root PVE API token
      # may set `nesting` but 403s on ANY fuse/keyctl value (even false), so
      # omitting them when off lets the IaC path create token-managed CTs
      # (INFRA-88).
      features = {
        nesting = meta.features.nesting;
      } // (lib.optionalAttrs meta.features.fuse { fuse = true; })
        // (lib.optionalAttrs meta.features.keyctl { keyctl = true; })
        // (lib.optionalAttrs meta.features.mknod { mknod = true; })
        // (lib.optionalAttrs (meta.features.mount != []) { mount = meta.features.mount; });
      console = { type = "console"; };
    } // mountConfig // sourceConfig
      // (lifecycleAttrs meta)
      // (lib.optionalAttrs (meta.devices != []) {
        device_passthrough = map (d:
          { path = d.path; }
          // lib.optionalAttrs (d.uid != null) { uid = d.uid; }
          // lib.optionalAttrs (d.gid != null) { gid = d.gid; }
          // lib.optionalAttrs (d.mode != null) { mode = d.mode; }
          // lib.optionalAttrs d.deny_write { deny_write = true; }
        ) meta.devices;
      })
      // (lib.optionalAttrs (meta.hook_script != null) { hook_script_file_id = meta.hook_script; })
      // (lib.optionalAttrs (meta.pool != null) { pool_id = meta.pool; })
      // (let d = computeDescription meta; in lib.optionalAttrs (d != null) { description = d; })
      // (mkNetwork (meta // { _name = name; })) // (mkLifecycle lifecycleMeta)
      # initConfig is recursive-merged LAST so its initialization.user_account
      # joins mkNetwork's initialization.{hostname,dns,ip_config} instead of
      # being clobbered by Nix's shallow // operator.
      // (let merged = lib.recursiveUpdate
            (((mkNetwork (meta // { _name = name; })).initialization or {}))
            (initConfig.initialization or {});
          in lib.optionalAttrs hasCustomImage { initialization = merged; });

  # ── KVM/QEMU VM emitter ───────────────────────────────────────
  mkVm = name: meta:
    let
      # ── New-style explicit image dispatch ──
      # If meta.image is set, parse it as either "file:<file_id>" or
      # "clone:<vmid>". Takes precedence over the legacy vm_template +
      # name-prefix dispatch below.
      imageStr = meta.image or null;
      imageParts = lib.optional (imageStr != null) (lib.splitString ":" imageStr);
      imageKind = if imageStr == null then null
                  else if lib.hasPrefix "file:" imageStr then "file"
                  else if lib.hasPrefix "clone:" imageStr then "clone"
                  else throw "mkVm(${name}): image must be \"file:...\" or \"clone:<vmid>\", got ${imageStr}";
      imageFileId = if imageKind == "file"
                    then lib.removePrefix "file:" imageStr
                    else null;
      imageCloneVmId = if imageKind == "clone"
                       then lib.toInt (lib.removePrefix "clone:" imageStr)
                       else null;

      # ── Legacy name-prefix dispatch — kept for VMs not yet migrated
      # to explicit `image` + `cloud_init.users`. Gradual migration:
      # set `image` on a VM entry and the new path activates for it. ──
      isNetgate = name == "netgate";
      isHeadscaleRouter = name == "headscale-router";
      fromNixosTemplate = meta.vm_template == "nixos";
      isDept = lib.hasPrefix "dept-" name;
      isDev = lib.hasPrefix "dev-" name;

      # Whether to use the new image-dispatch path or the legacy one.
      newStyle = imageStr != null;

      # Data disks → virtio1, virtio2, ... in declaration order.
      dataDiskEntries = lib.imap0 (i: dd: {
        interface = "virtio${toString (i + 1)}";
        datastore_id = dd.datastore_id;
        size = dd.size_gb;
      }) (meta.data_disks or []);

      # Legacy: hard-coded 128 GiB virtio1 for dev-* VMs that don't yet
      # declare data_disks. Drops out once dev-nithin migrates.
      legacyDevDataDisk =
        lib.optional (isDev && !newStyle && (meta.data_disks or []) == []) {
          interface = "virtio1"; datastore_id = "local-storage"; size = 128;
        };

      nicDefaults = {
        disconnected = false;
        enabled = true;
        firewall = false;
        mac_address = "";
        model = "virtio";
        mtu = 0;
        queues = 0;
        rate_limit = 0;
        trunks = "";
        vlan_id = 0;
      };
    in {
      provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
      node_name = resolveNode meta;
      vm_id = meta.vm_id;
      name = name;
      tags = meta.tags;
      started = meta.start_on_create;

      cpu = { cores = meta.cpu_cores; type = "host"; };
      memory = { dedicated = meta.memory_mb; };
      operating_system = { type = "l26"; };

      disk = [(
        if newStyle then (
          # New-style: dispatch on imageKind. For "clone:<vmid>" the
          # root disk is just a sized entry (clone block provides the
          # source); for "file:<file_id>" we set file_id.
          {
            interface = "virtio0"; datastore_id = "local-storage";
            size = meta.root_disk_gb;
          } // lib.optionalAttrs (imageKind == "file") { file_id = imageFileId; }
        )
        else if fromNixosTemplate then {
          interface = "virtio0"; datastore_id = "local-storage"; size = meta.root_disk_gb;
        } else throw "mkVm(${name}): the legacy Debian-VM disk path was removed (INFRA-137). The fleet has no KVM Debian guests — use a Debian LXC (kind=container + image), or set an explicit `image = \"file:...\"`/`\"clone:...\"`."
      )] ++ dataDiskEntries ++ legacyDevDataDisk;

      network_device = [
        (nicDefaults // {
          bridge = "vmbr0";
        } // lib.optionalAttrs isNetgate {
          mac_address = "BC:24:11:5B:EA:26";
        })
        (nicDefaults // {
          bridge = "vmbr1";
        } // lib.optionalAttrs isNetgate {
          mac_address = "BC:24:11:D0:E9:C0";
        })
      ];

      initialization = {
        datastore_id = "local-storage";
        type = "nocloud";
        dns = dnsFor meta;
      } // (
        # New-style: a custom user-data snippet is generated by
        # nix/fleet/resources.nix's renderCloudInitSnippet, uploaded as
        # local:snippets/<name>-user-data.yaml. NixOS clone VMs in
        # new-style still get just the sysadmin key via user_account
        # (no custom snippet needed) — distinguished by imageKind.
        if newStyle then (
          if imageKind == "clone" then {
            user_account = { username = "root"; keys = [ net.sysadmin_ssh_key ]; };
            ip_config = [
              { ipv4 = { address = "dhcp"; }; }
              { ipv4 = { address = internalCidr meta.internal_ip; }; }
            ];
          } else {
            user_data_file_id = "local:snippets/${name}-user-data.yaml";
            ip_config = [
              { ipv4 = { address = "dhcp"; }; }
              { ipv4 = { address = internalCidr meta.internal_ip; }; }
            ];
          }
        )
        else if isNetgate then {
          user_account = { username = "root"; keys = [ net.sysadmin_ssh_key ]; };
          ip_config = [
            { ipv4 = { address = lanCidr meta.ip; } // optGw net.lan_gateway; }
            { ipv4 = { address = internalCidr meta.internal_ip; }; }
          ];
        }
        else if isHeadscaleRouter then {
          # Subnet router: static IPs on both NICs so it has direct L2
          # presence on each subnet it advertises (the LAN via eth0 on
          # vmbr0, the internal net via eth1 on vmbr1).
          #
          # Default gateway is the LAN router on eth0, NOT netgate on
          # eth1: vmbr1's L2 between this VM and netgate is flaky
          # (probably the same bridge-bleed issue that confuses ARP
          # between vmbr0 and vmbr1 — packets between the headscale-
          # router and netgate's vmbr1 interface keep getting dropped).
          # The LAN router has real internet upstream anyway, and
          # netgate also uses it as its own default gateway.
          #
          # WAN-side address is pinned via
          # fleet.settings.network.staticWanCidrs (not meta.ip) so the
          # fleet entry can keep `ip = ""` — that makes the colmena
          # targetHost resolve to `internal_ip`. SSH from PVE to the
          # WAN address fails because netgate apparently bridges
          # vmbr0↔vmbr1 at L2 (eth1's MAC keeps showing up in PVE's
          # vmbr0 ARP table for the WAN IP), so colmena must reach the
          # host via vmbr1.
          user_account = { username = "root"; keys = [ net.sysadmin_ssh_key ]; };
          ip_config = [
            { ipv4 = {
                address = config.fleet.settings.network.staticWanCidrs.${name} or
                  (throw "mkVm(${name}): legacy headscale-router VMs need a WAN-side CIDR in fleet.settings.network.staticWanCidrs.\"${name}\"");
              } // optGw net.lan_gateway; }
            { ipv4 = { address = internalCidr meta.internal_ip; }; }
          ];
        }
        else if fromNixosTemplate then {
          # Generic NixOS-template VM (e.g. sysadmin workstation, ADR-017).
          # Cloud-init only seeds the sysadmin root SSH key — the host's
          # NixOS config (Colmena) creates user accounts and services.
          user_account = { username = "root"; keys = [ net.sysadmin_ssh_key ]; };
          ip_config = [
            { ipv4 = { address = "dhcp"; }; }
            { ipv4 = { address = internalCidr meta.internal_ip; }; }
          ];
        }
        else if isDept then {
          user_account = { username = "root"; keys = [ net.sysadmin_ssh_key ]; };
          ip_config = [
            { ipv4 = { address = "dhcp"; }; }
            { ipv4 = { address = internalCidr meta.internal_ip; }; }
          ];
        }
        else if isDev then {
          # Per-VM cloud-init snippet uploaded as kind="file" in
          # nix/fleet/resources.nix. The snippet does per-VM finalisation
          # (hostname, dev user, /data mount, Nix install) on top of the
          # image-baked Debian (docker, qemu-guest-agent, dev tools, see
          # ADR-018). See ADR-013.
          user_data_file_id = "local:snippets/${name}-user-data.yaml";
          ip_config = [
            { ipv4 = { address = "dhcp"; }; }
            { ipv4 = { address = internalCidr meta.internal_ip; }; }
          ];
        }
        else throw "mkVm: unknown VM class for ${name}"
      );

      # Agent enabled when the OS has qemu-guest-agent installed.
      # New-style: always on (prepared images bake it in; clone-from-template
      # VMs ship NixOS which also runs it). Legacy: only dev/nixos paths had it.
      agent = { enabled = newStyle || isDev || fromNixosTemplate; };

      # Always attach a serial socket so `qm terminal <vmid>` can reach the
      # guest console — essential for debugging stuck boots on non-NixOS VMs
      # (firstboot prompts, cloud-init failures, kernel panics). Cheap to keep
      # on every VM; pattern is the community-scripts default.
      serial_device = [{ device = "socket"; }];
    }
    // (lifecycleAttrs meta)
    // lib.optionalAttrs (!meta.onboot) { on_boot = false; }
    // lib.optionalAttrs (newStyle && imageKind == "clone") {
      clone = { vm_id = imageCloneVmId; datastore_id = "local-storage"; full = true; }
        // lib.optionalAttrs (meta ? cloneFrom && false) {};  # placeholder for cross-host clones
    }
    // lib.optionalAttrs (!newStyle && fromNixosTemplate) {
      clone = { vm_id = 9000; datastore_id = "local-storage"; full = true; };
    }
    // lib.optionalAttrs (meta.pool != null) { pool_id = meta.pool; }
    // (let d = computeDescription meta; in lib.optionalAttrs (d != null) { description = d; })
    // (mkLifecycle meta);

  # ── Non-OS resource emitters ──────────────────────────────────
  mkBridge = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    node_name = resolveNode meta;
    name = name;
    ports = meta.ports or [];
    address = meta.address or null;
    autostart = meta.autostart or true;
    comment = meta.comment or "";
  } // (mkLifecycle meta);

  mkPool = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    pool_id = meta.pool_id;
    comment = meta.comment or "";
  } // (mkLifecycle meta);

  # Cluster-wide PVE group. Pre-declared so ACLs (mkAcl) have a group to
  # bind to on a fresh cluster — PVE rejects an ACL whose group_id doesn't
  # yet exist. For Authentik-synced groups the OIDC realm's groups-autocreate
  # would also create them, but only at first login; declaring them here makes
  # the ACL apply order-independent (INFRA-130 / ADR-071). Membership stays
  # IdP-driven (computed `members`, not managed here).
  mkGroup = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    group_id = meta.group_id;
    comment = meta.comment or "";
  } // (mkLifecycle meta);

  # `depends_on` (optional): list of TF resource addresses, e.g.
  # [ "proxmox_virtual_environment_group.platform-admins-group" ]. Used to
  # force group-before-ACL ordering within a single apply, since group_id is
  # a literal string and creates no implicit dependency edge (INFRA-130).
  mkAcl = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    path = meta.path;
    role_id = meta.role_id;
    group_id = meta.group_id or null;
    user_id = meta.user_id or null;
    token_id = meta.token_id or null;
    propagate = meta.propagate or true;
  } // (lib.optionalAttrs (meta ? depends_on && meta.depends_on != [])
         { depends_on = meta.depends_on; })
    // (mkLifecycle meta);

  mkDns = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    node_name = resolveNode meta;
    domain = meta.domain;
    servers = meta.servers;
  } // (mkLifecycle meta);

  mkDownload = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    node_name = resolveNode meta;
    datastore_id = meta.datastore_id;
    content_type = meta.content_type;
    url = meta.url;
    file_name = meta.file_name;
    overwrite = meta.overwrite or false;
  } // (lib.optionalAttrs (meta ? upload_timeout) { upload_timeout = meta.upload_timeout; })
    // (mkLifecycle meta);

  # File resource. Two source modes:
  #   • inline string content (default) — emits `source_raw`. Used for
  #     cloud-init snippets and hookscripts.
  #   • binary file (set meta.source = "nixos-lxc-image") — emits
  #     `source_file` pointing at a nix-built image. The bpg provider SCPs
  #     the file up to PVE on apply.
  # (The "debian-cloud-image" source was removed with the Debian-VM path —
  #  INFRA-137.)
  mkFile = name: meta:
    let
      sourceBlock =
        if (meta.source or null) == "nixos-lxc-image" then
          assert lib.assertMsg (preparedNixosLxcTemplatePath != null)
            "mkFile: meta.source=\"nixos-lxc-image\" requires pkgs to be in scope.";
          { source_file = [{
              path = preparedNixosLxcTemplatePath;
              file_name = meta.file_name;
            }];
          }
        else
          { source_raw = [{
              data = meta.data;
              file_name = meta.file_name;
              resize = 0;
            }];
          };
    in {
      provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
      node_name = resolveNode meta;
      datastore_id = meta.datastore_id;
      content_type = meta.content_type;
      overwrite = meta.overwrite or true;
    } // sourceBlock // (mkLifecycle meta);

  # External metric server (cluster-wide). PVE pushes node/guest/storage
  # stats to it. We use the OpenTelemetry plugin (OTLP/HTTP) → the Alloy
  # gateway on the otel CT (INFRA-47 / ADR-038). Only proto + path are set;
  # the bpg provider doesn't yet expose headers/TLS-verify (issue #2594),
  # which is why the gateway listens unauthenticated on the internal net.
  mkMetricsServer = name: meta: {
    provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
    name = meta.server_name or name;
    server = meta.server;
    port = meta.port;
    type = "opentelemetry";
    opentelemetry_proto = meta.opentelemetry_proto or "http";
    opentelemetry_path = meta.opentelemetry_path or "/v1/metrics";
  } // lib.optionalAttrs (meta ? disable) { disable = meta.disable; }
    // (mkLifecycle meta);

  # Datacenter-level options (singleton per cluster). The only field
  # we currently set is `description`, rendered from the structured
  # `note` attribute by templates/proxmox/mkDatacenterNote.
  mkClusterOptions = name: meta:
    let
      base = {
        provider = "proxmox.${builtins.elemAt (lib.strings.splitString "." meta.provider_instance) 1}";
        # Set keyboard explicitly to match the bpg/proxmox provider's default.
        # Otherwise the provider injects "en-us" on read and tofu detects
        # this as drift on every plan, forcing destroy + recreate cycles.
        keyboard = meta.keyboard or "en-us";
      } // lib.optionalAttrs (meta ? note && meta.note != null) {
        description = notes.mkDatacenterNote meta.note;
      };
      # Provider returns `description` with different markdown-link escaping
      # than was sent → "Provider produced inconsistent result after apply".
      # Force-merge `ignore_changes = [ "description" ]` into the lifecycle
      # block on top of whatever mkLifecycle already emits (protect, etc.).
      metaWithIgnore = meta // {
        ignore_changes = (meta.ignore_changes or []) ++ [ "description" ];
      };
    in base // mkLifecycle metaWithIgnore;
}
