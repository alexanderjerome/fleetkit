{ lib, ... }:

# Shared carlpett/sops provider config.
#
# Every stack's generated config.tf.json includes this block. The sops
# provider reads nix/secrets/secrets.yaml at `tofu apply` time using the
# age key from SOPS_AGE_KEY (exported by nix/shell.nix). Secrets are
# referenced elsewhere as:
#   ${data.sops_file.secrets.data["integrations.proxmox.password"]}

{
  terraform.required_providers.sops = {
    source = "carlpett/sops";
    version = "~> 1.1";
  };

  # Path is relative to the workdir at `tofu apply` time. The fleet CLI
  # copies config.tf.json into .tf/<stack-slug>/, so the relative path
  # from there back to the repo's SOPS file is two parents up.
  data.sops_file.secrets = {
    source_file = "../../nix/secrets/secrets.yaml";
  };
}
