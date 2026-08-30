{ ... }:

{
  imports = [
    ./proxmox.nix
    ./xen-orchestra.nix
    ./cloudflare.nix
    ./grafana.nix
  ];
}
