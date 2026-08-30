{ lib }:

# Helper: translate a SOPS path like "integrations/proxmox/password"
# into the Terraform interpolation
#   ${data.sops_file.secrets.data["integrations.proxmox.password"]}
# that the carlpett/sops provider resolves at apply time.
#
# bpg/sops uses dots as separators in the data key; our SOPS YAML file
# uses YAML nesting. We just swap slashes for dots.

rec {
  sopsRef = path:
    "\${data.sops_file.secrets.data[\"${lib.replaceStrings [ "/" ] [ "." ] path}\"]}";

  # Given an attrset of `{ providerConfigKey = sopsPath; ... }`, return
  # the same attrset with each path replaced by its interpolation.
  resolveSecrets = secrets: lib.mapAttrs (_: sopsRef) secrets;
}
