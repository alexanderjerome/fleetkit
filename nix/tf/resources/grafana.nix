{ config, lib, stackId ? null, ... }:

# Emits Grafana Cloud resources (INFRA-144) for entries in the current
# stack (normally all in `platform.grafana-cloud`):
#
#   kind = "sm-check"                  → grafana_synthetic_monitoring_check
#                                        (+ one shared probes data source;
#                                        probe NAMES resolve to IDs at plan)
#   kind = "grafana-contact-point"     → grafana_contact_point (slack)
#   kind = "grafana-message-template"  → grafana_message_template
#
# Check entries are built with nix/lib/tf/grafana.nix mkHttpCheck /
# mkTcpCheck — see there for the host-attachable constructor contract.
# Pre-existing contact points / templates are IMPORTED by name:
#   sk deploy tf import platform.grafana-cloud grafana_message_template.<n> "<name>"

let
  resourcesInStack = lib.filterAttrs
    (_: r: "${r.env}.${r.stack}" == stackId)
    config.fleet.resources;

  byKind = lib.groupBy (r: r.kind)
    (lib.mapAttrsToList
      (name: meta: meta // { _name = name; })
      resourcesInStack);

  checks        = byKind."sm-check" or [];
  contactPoints = byKind."grafana-contact-point" or [];
  templates     = byKind."grafana-message-template" or [];
  folders       = byKind."grafana-folder" or [];
  ruleGroups    = byKind."grafana-rule-group" or [];

  sopsLib = import ../../lib/tf/sops.nix { inherit lib; };
  safeName = s: lib.replaceStrings [ "-" "." " " ] [ "_" "_" "_" ] s;

  probeRef = name:
    "\${data.grafana_synthetic_monitoring_probes.main.probes.${name}}";

  mkCheck = e: lib.nameValuePair (safeName e._name) {
    job = e.job;
    target = e.target;
    enabled = e.enabled;
    probes = map probeRef e.probes;
    frequency = e.frequency_seconds * 1000;
    timeout = e.timeout_seconds * 1000;
    alert_sensitivity = e.alert_sensitivity;
    basic_metrics_only = true;
    labels = e.labels;
    settings = [
      (if e.check_type == "http"
       then { http = [ e.http_settings ]; }
       else { tcp = [ e.tcp_settings ]; })
    ];
  };

  # slack.webhook_sops is a SOPS path (never a literal URL); other slack.*
  # keys pass through to the provider's slack block (text, recipient, …).
  mkContactPoint = e: lib.nameValuePair (safeName e._name) {
    name = e.contact_name;
    slack = [
      ((removeAttrs e.slack [ "webhook_sops" ]) // {
        url = sopsLib.sopsRef e.slack.webhook_sops;
      })
    ];
    # Keep UI-editable: these predate terranix and the team tweaks alert
    # copy in the Cloud UI. Terranix owns the baseline; provenance stays off.
    disable_provenance = true;
  };

  mkTemplate = e: lib.nameValuePair (safeName e._name) {
    name = e.template_name;
    template = e.template;
    # Unlike contact points, `true` here churns forever on Grafana Cloud:
    # the API accepts X-Disable-Provenance on template PUT but the
    # provider reads the flag back as false → perpetual forced
    # replacement ("inconsistent result after apply"). `false` matches
    # what the provider reads; templates end up UI-locked (provisioned),
    # which is the stricter IaC posture anyway.
    disable_provenance = false;
  };
  mkFolder = e: lib.nameValuePair (safeName e._name) {
    title = e.folder_title;
  };

  # Grafana-managed alert rule group. Each rule's `data` entries carry a
  # Nix attrset `model` that is JSON-encoded here (the provider expects a
  # jsonencode'd string). `folder` names a sibling grafana-folder entry;
  # the uid is referenced so tofu orders folder→rules.
  mkRuleGroup = e: lib.nameValuePair (safeName e._name) {
    name = e.group_name;
    folder_uid = "\${grafana_folder.${safeName e.folder}.uid}";
    interval_seconds = e.interval_seconds or 60;
    rule = map (r: {
      name = r.name;
      condition = r.condition;
      for = r.for or "5m";
      no_data_state = r.no_data_state or "OK";
      exec_err_state = r.exec_err_state or "KeepLast";
      annotations = r.annotations or {};
      labels = r.labels or {};
      data = map (d: {
        ref_id = d.ref_id;
        datasource_uid = d.datasource_uid;
        relative_time_range = d.relative_time_range or { from = 600; to = 0; };
        model = builtins.toJSON (d.model // { refId = d.ref_id; });
      }) r.data;
    }) e.rules;
  };
in {
  config = lib.mkIf (stackId != null && (checks ++ contactPoints ++ templates ++ folders ++ ruleGroups) != []) {
    data.grafana_synthetic_monitoring_probes =
      lib.mkIf (checks != []) { main = {}; };

    resource.grafana_synthetic_monitoring_check =
      lib.mkIf (checks != []) (lib.listToAttrs (map mkCheck checks));

    resource.grafana_contact_point =
      lib.mkIf (contactPoints != []) (lib.listToAttrs (map mkContactPoint contactPoints));

    resource.grafana_message_template =
      lib.mkIf (templates != []) (lib.listToAttrs (map mkTemplate templates));

    resource.grafana_folder =
      lib.mkIf (folders != []) (lib.listToAttrs (map mkFolder folders));

    resource.grafana_rule_group =
      lib.mkIf (ruleGroups != []) (lib.listToAttrs (map mkRuleGroup ruleGroups));
  };
}
