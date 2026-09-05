{ config, lib, ... }:

# Shared carlpett/sops provider config.
#
# Every stack's generated config.tf.json includes this block. The sops
# provider reads the fleet's SOPS file at `tofu apply` time using the age
# key from SOPS_AGE_KEY (exported by nix/shell.nix). Secrets are referenced
# elsewhere as:
#   ${data.sops_file.secrets.data["integrations.proxmox.password"]}
#
# WHICH file is `fleet.settings.tfSopsFile`. It defaults to the fleet's main
# secrets file, but a fleet that splits its SOPS store by resource group will
# keep the provider credentials the tf layer reads (integrations.*) in a
# different file from the one NixOS hosts default to — and this data source
# has to follow them. Hardcoding it produced a failure that stayed hidden for
# days: the state backend was failing first, so nobody got far enough into
# `tofu plan` to see the sops lookup miss.

let
  sopsFile = config.fleet.settings.tfSopsFile;
in
{
  terraform.required_providers.sops = {
    source = "carlpett/sops";
    version = "~> 1.1";
  };

  # Path is relative to the workdir at `tofu apply` time. The fleet CLI
  # copies config.tf.json into .tf/<stack-slug>/, so the relative path
  # from there back to a repo-root-relative file is two parents up.
  data.sops_file.secrets = {
    source_file = "../../${sopsFile}";
  };
}
