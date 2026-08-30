{ lib }:

# Proxmox-specific note renderers.
#
# - `mkNote`           → markdown for the Notes panel of a VM/LXC
#                        (bpg `description` attribute on
#                        proxmox_virtual_environment_{container,vm}).
# - `mkDatacenterNote` → markdown for Datacenter → Notes
#                        (bpg `description` attribute on
#                        proxmox_virtual_environment_cluster_options).
#
# PVE renders these via marked.js with sanitization. CommonMark works,
# inline `<img>` works for reachable URLs, raw HTML mostly doesn't.
# Stick to markdown unless you've confirmed a tag survives sanitization.

let
  md = import ../common/markdown.nix { inherit lib; };

  # Renders a `services` table when entries are present.
  servicesTable = services:
    if services == [] then ""
    else md.table {
      headers = [ "Service" "Address" "Port" ];
      rows = map (s: [
        s.name
        (if s.address == "" then "—" else s.address)
        (if s.port == null then "—" else toString s.port)
      ]) services;
    };

  linksList = items:
    if items == [] then ""
    else md.bulletList (map md.link items);

in {
  # Per-VM/LXC note. All fields optional except presence — the renderer
  # quietly skips empty sections so a sparse `note = { summary = "..."; }`
  # produces a single-paragraph Notes panel.
  mkNote = note:
    let
      header = if note.title == "" then "" else md.heading 1 note.title;

      statefulBanner =
        if note.stateful
        then "> ⚠️ **STATEFUL — protected** · destruction blocked by `prevent_destroy`"
        else "";

      networkSection = md.section {
        title = "Network";
        body = servicesTable note.services;
      };

      linksSection = md.section {
        title = "Links";
        body = linksList note.links;
      };
    in
      md.join [ header statefulBanner note.summary networkSection linksSection note.extra ];

  # Datacenter-level note (Proxmox-only; XO has no equivalent).
  mkDatacenterNote = note:
    let
      header = md.heading 1 note.title;

      linksSection = md.section {
        title = "Links";
        body = linksList note.links;
      };

      observabilitySection = md.section {
        title = "Observability";
        body = linksList note.observability;
      };
    in
      md.join [ header note.summary linksSection observabilitySection (note.extra or "") ];
}
