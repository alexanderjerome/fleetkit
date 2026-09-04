{ ... }:

# Fixture fleet for the compute-surface golden check (nix/checks.nix).
#
# One host per emitter code path, so the rendered Terraform JSON of every
# path is pinned in nix/checks/golden/compute-surface/ and any change to
# nix/lib/tf/proxmox.nix, nix/fleet/compute.nix or the validators shows up
# as a diff. Documentation-range values only (RFC5737, example.*).
#
# Two leaf stacks (golden.lxc / golden.vm) so per-stack filtering is
# exercised too. Nothing here may embed a store path (no
# source = "nixos-lxc-image" files, no ansible provider) — the goldens
# must be byte-stable across nixpkgs bumps.

let
  pi = "proxmox.golden";
  lxc = extra: {
    env = "golden"; stack = "lxc"; provider_instance = pi; kind = "container";
    node = "pve1"; root_disk_datastore = "local-lvm";
  } // extra;
  vm = extra: {
    env = "golden"; stack = "vm"; provider_instance = pi; kind = "vm";
    node = "pve2";
  } // extra;
in
{
  config.fleet.settings.adminSshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOLDENGOLDENGOLDENGOLDENGOLDENGOLDENGOLDEN operator@example.test"
  ];
  config.fleet.settings.network.staticWanCidrs.headscale-router = "198.51.100.7/24";

  config.fleet.network = {
    sysadmin_ssh_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOLDENGOLDENGOLDENGOLDENGOLDENGOLDENGOLDEN sysadmin@example.test";
    gateway = "192.0.2.1";
    lan_gateway = "198.51.100.1";
    dns_domain = "golden.test";
    dns_servers = [ "192.0.2.53" "1.1.1.1" ];
  };

  config.fleet.providers.proxmox.golden = {
    source = "bpg/proxmox";
    version = "~> 0.103";
    endpoint = "https://198.51.100.2:8006";
    secrets.api_token = "integrations/proxmox/golden/api_token";
    state.prefix = "tf/proxmox-golden";
    cluster = { nodes = [ "pve1" "pve2" ]; primary_node = "pve1"; };
  };

  config.fleet.resources = {
    golden-pool = { env = "golden"; stack = "lxc"; provider_instance = pi; kind = "pool"; pool_id = "golden"; comment = "fixture pool"; };
    vmbr9 = { env = "golden"; stack = "lxc"; provider_instance = pi; kind = "bridge"; node = "pve1"; ports = [ "eth9" ]; comment = "fixture bridge"; };
  };

  # ── LXC: one host per legacy network_mode + source path ──
  config.fleet.compute = {
    lxc-internal = lxc { vm_id = 9101; internal_ip = "192.0.2.101"; tags = [ "golden" ]; pool = "golden"; notes = "single-internal (default)"; };
    lxc-external = lxc { vm_id = 9102; ip = "198.51.100.102"; network_mode = "single-external"; };
    lxc-dual = lxc { vm_id = 9103; ip = "198.51.100.103"; internal_ip = "192.0.2.103"; network_mode = "dual";
      mount_points = [ { datastore = "local-lvm"; path = "/data"; size = "8G"; } ];
      features = { nesting = true; fuse = true; keyctl = true; }; };
    lxc-netgate = lxc { vm_id = 9104; ip = "198.51.100.104"; internal_ip = "192.0.2.104"; network_mode = "custom-netgate"; privileged = true; };
    lxc-btc = lxc { vm_id = 9105; internal_ip = "192.0.2.105"; network_mode = "custom-btc-testnet"; features = { nesting = false; fuse = false; keyctl = false; }; };
    lxc-router = lxc { vm_id = 9106; ip = "198.51.100.106"; internal_ip = "192.0.2.106"; network_mode = "lxc-router";
      privileged = true; mac_address_eth0 = "BC:24:11:00:00:06"; host_managed = true; protect = true; };
    lxc-clone = lxc { vm_id = 9107; internal_ip = "192.0.2.107"; cloneFrom = 9000; mount_points = [ { datastore = "local-lvm"; path = "/srv"; size = "4G"; backup = false; } ]; };
    lxc-debian = lxc { vm_id = 9108; internal_ip = "192.0.2.108"; image = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst";
      ignore_changes = [ "tags" ]; note = { title = "Debian guest"; summary = "structured note"; stateful = true; }; };

    # ── LXC: new surface (PLAN.md Appendix A, commits 4-5) ──
    lxc-lifecycle = lxc { vm_id = 9109; internal_ip = "192.0.2.109";
      protection = true; onboot = false; start_on_create = false;
      startup = { order = 5; up_delay = 20; };
      dns = { servers = [ "192.0.2.54" ]; domain = "lab.golden.test"; }; };
    lxc-devices = lxc { vm_id = 9110; internal_ip = "192.0.2.110"; arch = "arm64";
      features = { mknod = true; mount = [ "nfs" "cifs" ]; };
      devices = [ { path = "/dev/net/tun"; } { path = "/dev/dri/renderD128"; gid = 44; mode = "0660"; } { path = "/dev/apex_0"; deny_write = true; } ];
      hook_script = "local:snippets/golden-hook.sh"; dns.domain = ""; };

    # ── VM: every mkVm class ──
    netgate = vm { vm_id = 9201; ip = "198.51.100.201"; internal_ip = "192.0.2.201"; vm_template = "nixos"; tags = [ "golden" ]; };
    headscale-router = vm { vm_id = 9202; internal_ip = "192.0.2.202"; vm_template = "nixos"; };
    vm-nixos-template = vm { vm_id = 9203; internal_ip = "192.0.2.203"; vm_template = "nixos"; cpu_cores = 4; memory_mb = 4096; root_disk_gb = 32; };
    vm-clone = vm { vm_id = 9204; internal_ip = "192.0.2.204"; image = "clone:9000"; data_disks = [ { size_gb = 100; mount_path = "/data"; } ]; };
    vm-lifecycle = vm { vm_id = 9206; internal_ip = "192.0.2.206"; vm_template = "nixos";
      protection = true; onboot = false; start_on_create = false; startup = { order = 1; down_delay = 60; };
      dns.servers = [ "192.0.2.54" ]; };
    vm-file = vm { vm_id = 9205; internal_ip = "192.0.2.205"; image = "file:local:iso/example-cloud-amd64.qcow2";
      cloud_init = { users = [ { name = "operator"; ssh_keys = [ "ssh-ed25519 AAAAGOLDEN operator@example.test" ]; } ]; runcmd = [ "echo golden" ]; }; };
  };

  config.fleet.hostsRegistry = {
    lxc-internal = { ... }: { infra.networking.singleInterface = true; };
  };
}
