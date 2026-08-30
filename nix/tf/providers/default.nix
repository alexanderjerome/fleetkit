{ ... }:

{
  imports = [
    ./sops.nix
    ./proxmox
    ./proxmox-backup-server.nix
    ./xen-orchestra.nix
    ./cloudflare.nix
    ./grafana.nix
    ./utility.nix
    ./docker.nix
  ];
}
