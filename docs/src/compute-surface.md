# Compute surface and networking modes

Every knob the community-scripts LXC/VM wizard asked for has a home in
`fleet.compute.<name>` (see the [fleet.compute](./fleet/compute.md)
reference). This page maps the two.

## From the wizard to `fleet.compute`

| community-scripts (`build.func` / `vm-core.func`) | fleetkit |
|---|---|
| `CT_TYPE` / `var_unprivileged` | `privileged` |
| `CT_ID` / `VMID` | `vm_id` |
| `HN` | attribute name / `name` |
| `DISK_SIZE`, `CORE_COUNT`, `RAM_SIZE` | `root_disk_gb`, `cpu_cores`, `memory_mb` (+ `swap_mb`) |
| storage picker (`var_container_storage`) | `root_disk_datastore` (default `fleet.settings.providers.proxmox.defaultDatastore`) |
| template storage (`var_template_storage`) | `fleet.settings.providers.proxmox.lxcTemplateDatastore` |
| `BRG` / SDN vnet | `interfaces[].bridge` / `interfaces[].vnet` (+ `sdn-zone`/`sdn-vnet` resources) |
| `NET` dhcp / static / range | `interfaces[].ipv4` = `"dhcp"` / `"a.b.c.d/nn"` (ranges are not declarative) |
| `GATE` | `interfaces[].gateway` |
| `IPV6_METHOD` auto/dhcp/static/none/disable | `interfaces[].ipv6.method` (disable ≡ none) |
| `MTU`, `VLAN`, `MAC` | `interfaces[].mtu`, `.vlan`, `.mac` |
| `NS`, `SD` | `dns.servers`, `dns.domain` |
| `ENABLE_FUSE`, `ENABLE_NESTING`, `ENABLE_KEYCTL`, `ENABLE_MKNOD`, `ALLOW_MOUNT_FS` | `features.{fuse,nesting,keyctl,mknod,mount}` |
| `ENABLE_TUN`, `ENABLE_GPU`, Coral, USB serial | `devices` (+ `lxc_extra_conf` for hot-plug cgroup rules) |
| `PROTECT_CT` | `protection` |
| `TAGS` | `tags` |
| `var_post_install` hook | `hook_script` (PVE hook), or a NixOS activation script |
| `CT_TIMEZONE` | NixOS `time.timeZone` in the host's `hostsRegistry` entry |
| `PW`, `SSH`, `SSH_AUTHORIZED_KEY` | not applicable: NixOS hosts are key-only (`fleet.network.sysadmin_ssh_key`), root has no password |
| `APT_CACHER`, `HTTP_PROXY`, `INHERIT_HOST_CA` | NixOS `nix.settings.substituters`, `networking.proxy`, `security.pki` |
| VM `MACHINE`, `BIOS`, `CPU_TYPE`, `DISK_CACHE`, `scsihw`, `-tablet 0` | `vm.machine`, `vm.bios` (+ `vm.efi`), `vm.cpu_type`, `vm.root_disk.cache`, `vm.scsi_hardware`, `vm.tablet` |
| VM cloud-init on/off | `cloud_init.enable`, `cloud_init.datastore` |
| VM cloud image (`qm importdisk`) | `image = "import:<datastore>:import/<file>"` with a `download` resource |
| `START_VM`, `-onboot 1` | `start_on_create`, `onboot`, `startup` |

## Network modes

`network_mode = "declared"` is the general form: `interfaces` lists every
NIC with its bridge or VNet, IPv4 (`dhcp`, `manual`, or a CIDR with an
explicit prefix), gateway, IPv6, VLAN, MTU, MAC and firewall flag; entry
*i* becomes `net<i>` (LXC: `eth<i>`).

The fixed shapes (`single-internal`, `single-external`, `dual`,
`lxc-router`, `custom-*`) predate it and remain for existing fleets. They
append `fleet.network.internal_prefix_len` / `lan_prefix_len` (derived
from the CIDRs, else 24) to the bare `internal_ip` / `ip`. New hosts
should use `declared`; the legacy modes will be deprecated once the
origin fleet has migrated.

## Escape hatch

`lxc_extra_conf` writes raw lines into `/etc/pve/lxc/<vmid>.conf` inside a
marker block through a `terraform_data` local-exec over root SSH to the
node (`fleet.providers.proxmox.<inst>.cluster.node_addresses`). Use it
only for what `devices` cannot express.
