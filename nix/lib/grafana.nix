# nix/lib/grafana.nix — Reusable Grafana dashboard, panel, and alert builders.
#
# Provides typed constructors for every Grafana provisioning primitive:
# panels, targets, dashboards, alert rules, contact points, and routing policies.
#
# Usage:
#   grafana = import ../../lib/grafana.nix { inherit lib; };
#   grafana.mkDashboard { title = "My Dashboard"; uid = "my-dash"; panels = [ ... ]; }
#
{ lib }:
let
  inherit (lib) optionalAttrs imap0 concatStringsSep;

  # ── Datasource references ─────────────────────────────────────
  # UIDs must match the provisioned datasources in grafana-stack/default.nix.
  ds = {
    prometheus = { type = "prometheus"; uid = "prometheus"; };
    loki       = { type = "loki";       uid = "loki"; };
    tempo      = { type = "tempo";      uid = "tempo"; };
    # Grafana 11+ renamed the built-in postgres plugin; Grafana 12 drops the old name entirely.
    postgres   = { type = "grafana-postgresql-datasource"; uid = "timescaledb"; };
    grafana    = { type = "grafana";    uid = "-- Grafana --"; };
    dashboard  = { type = "datasource"; uid = "-- Dashboard --"; };
    expr       = { type = "__expr__";   uid = "__expr__"; };
  };

  # ── Threshold presets ─────────────────────────────────────────
  # Named _thresholds internally to avoid shadowing in function argument defaults
  # (where `thresholds ? thresholds.none` would self-reference). Exported as `thresholds`.
  _thresholds = {
    # Higher is worse (CPU, memory, disk usage)
    usage = {
      mode = "absolute";
      steps = [
        { color = "green";  value = null; }
        { color = "yellow"; value = 70; }
        { color = "red";    value = 90; }
      ];
    };
    # Lower is worse (health, sync progress, availability)
    health = {
      mode = "absolute";
      steps = [
        { color = "red";    value = null; }
        { color = "yellow"; value = 0.5; }
        { color = "green";  value = 0.99; }
      ];
    };
    # Binary up/down
    binary = {
      mode = "absolute";
      steps = [
        { color = "red";   value = null; }
        { color = "green"; value = 1; }
      ];
    };
    # Queue depth (0 = good, accumulation = bad)
    queue = {
      mode = "absolute";
      steps = [
        { color = "green";  value = null; }
        { color = "yellow"; value = 10; }
        { color = "red";    value = 50; }
      ];
    };
    # Single color, no thresholds
    none = {
      mode = "absolute";
      steps = [
        { color = "green"; value = null; }
      ];
    };
  };

  # ── Grid position helpers ─────────────────────────────────────
  # n = column index (0-based), y = row offset
  pos = {
    full    = y:   { h = 8; w = 24; x = 0;      inherit y; };
    half    = n: y: { h = 8; w = 12; x = n * 12; inherit y; };
    third   = n: y: { h = 8; w = 8;  x = n * 8;  inherit y; };
    quarter = n: y: { h = 6; w = 6;  x = n * 6;  inherit y; };
    stat    = n: y: { h = 4; w = 6;  x = n * 6;  inherit y; };
    custom  = args: args;
  };

  # ═══════════════════════════════════════════════════════════════
  #  Target builders
  # ═══════════════════════════════════════════════════════════════

  mkPromTarget = {
    expr,
    legendFormat ? "{{instance}}",
    refId ? "A",
    instant ? false,
    format ? "time_series",
    datasource ? ds.prometheus
  }: {
    inherit datasource expr legendFormat refId;
  } // optionalAttrs instant { inherit instant; }
    // optionalAttrs (format != "time_series") { inherit format; };

  mkLokiTarget = {
    expr,
    legendFormat ? "",
    refId ? "A",
    datasource ? ds.loki
  }: {
    inherit datasource expr legendFormat refId;
  };

  mkSqlTarget = {
    rawSql,
    refId ? "A",
    format ? "table",
    datasource ? ds.postgres
  }: {
    inherit datasource rawSql refId format;
  };

  mkTempoTarget = {
    query,
    refId ? "A",
    queryType ? "traceqlSearch",
    datasource ? ds.tempo
  }: {
    inherit datasource refId queryType query;
  };

  # ═══════════════════════════════════════════════════════════════
  #  Panel builders
  # ═══════════════════════════════════════════════════════════════

  mkRow = { title, y ? 0, id ? 0, collapsed ? false }: {
    inherit title id collapsed;
    type = "row";
    gridPos = { h = 1; w = 24; x = 0; inherit y; };
    panels = [];
  };

  # Internal: timeseries `custom` fieldConfig block (the main boilerplate source)
  _timeseriesCustom = {
    fillOpacity ? 10,
    lineWidth ? 1,
    drawStyle ? "line",
    lineInterpolation ? "linear",
    stacking ? "none",
    spanNulls ? false
  }: {
    axisBorderShow = false;
    axisCenteredZero = false;
    axisColorMode = "text";
    axisLabel = "";
    axisPlacement = "auto";
    barAlignment = 0;
    inherit drawStyle fillOpacity lineWidth lineInterpolation spanNulls;
    gradientMode = "none";
    hideFrom = { legend = false; tooltip = false; viz = false; };
    insertNulls = false;
    pointSize = 5;
    scaleDistribution.type = "linear";
    showPoints = "never";
    stacking = { group = "A"; mode = stacking; };
    thresholdsStyle.mode = "off";
  };

  mkTimeseriesPanel = {
    title,
    targets,
    gridPos,
    id ? 0,
    unit ? null,
    decimals ? null,
    min ? null,
    max ? null,
    thresholds ? _thresholds.none,
    fillOpacity ? 10,
    lineWidth ? 1,
    drawStyle ? "line",
    lineInterpolation ? "linear",
    stacking ? "none",
    spanNulls ? false,
    legendMode ? "list",
    legendPlacement ? "bottom",
    legendCalcs ? [],
    tooltipMode ? "multi",
    overrides ? []
  }: {
    type = "timeseries";
    inherit title targets gridPos id;
    fieldConfig = {
      defaults = {
        color.mode = "palette-classic";
        custom = _timeseriesCustom {
          inherit fillOpacity lineWidth drawStyle lineInterpolation stacking spanNulls;
        };
        mappings = [];
        inherit thresholds;
      } // optionalAttrs (unit != null) { inherit unit; }
        // optionalAttrs (decimals != null) { inherit decimals; }
        // optionalAttrs (min != null) { inherit min; }
        // optionalAttrs (max != null) { inherit max; };
      inherit overrides;
    };
    options = {
      legend = {
        calcs = legendCalcs;
        displayMode = legendMode;
        placement = legendPlacement;
        showLegend = true;
      };
      tooltip = { mode = tooltipMode; sort = "none"; };
    };
  };

  mkStatPanel = {
    title,
    targets,
    gridPos,
    id ? 0,
    unit ? null,
    decimals ? null,
    thresholds ? _thresholds.none,
    colorMode ? "value",
    graphMode ? "area",
    mappings ? [],
    overrides ? []
  }: {
    type = "stat";
    inherit title targets gridPos id;
    fieldConfig = {
      defaults = {
        color.mode = "thresholds";
        inherit mappings thresholds;
      } // optionalAttrs (unit != null) { inherit unit; }
        // optionalAttrs (decimals != null) { inherit decimals; };
      inherit overrides;
    };
    options = {
      inherit colorMode graphMode;
      justifyMode = "auto";
      orientation = "auto";
      textMode = "auto";
      showPercentChange = false;
      wideLayout = true;
      reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; };
    };
  };

  mkGaugePanel = {
    title,
    targets,
    gridPos,
    id ? 0,
    unit ? "percentunit",
    decimals ? null,
    min ? 0,
    max ? 1,
    thresholds ? _thresholds.health,
    overrides ? []
  }: {
    type = "gauge";
    inherit title targets gridPos id;
    fieldConfig = {
      defaults = {
        color.mode = "thresholds";
        inherit thresholds min max unit;
        mappings = [];
      } // optionalAttrs (decimals != null) { inherit decimals; };
      inherit overrides;
    };
    options = {
      orientation = "auto";
      showThresholdLabels = false;
      showThresholdMarkers = true;
      sizing = "auto";
      minVizHeight = 75;
      minVizWidth = 75;
      reduceOptions = { calcs = [ "lastNotNull" ]; fields = ""; values = false; };
    };
  };

  mkTablePanel = {
    title,
    targets,
    gridPos,
    id ? 0,
    transformations ? [],
    overrides ? [],
    sortBy ? []
  }: {
    type = "table";
    inherit title targets gridPos id transformations;
    fieldConfig = {
      defaults = {};
      inherit overrides;
    };
    options = {
      showHeader = true;
    } // optionalAttrs (sortBy != []) { inherit sortBy; };
  };

  mkTextPanel = {
    title,
    content,
    gridPos,
    id ? 0,
    mode ? "markdown"
  }: {
    type = "text";
    inherit title gridPos id;
    datasource = ds.dashboard;
    options = { inherit mode content; };
  };

  mkBarChartPanel = {
    title,
    targets,
    gridPos,
    id ? 0,
    unit ? null,
    orientation ? "auto",
    stacking ? "normal",
    overrides ? []
  }: {
    type = "barchart";
    inherit title targets gridPos id;
    fieldConfig = {
      defaults = {
        color.mode = "palette-classic";
        custom = {
          axisBorderShow = false;
          fillOpacity = 80;
          gradientMode = "none";
          stacking.mode = stacking;
        };
      } // optionalAttrs (unit != null) { inherit unit; };
      inherit overrides;
    };
    options = {
      barRadius = 0;
      groupWidth = 0.7;
      barWidth = 0.97;
      inherit orientation;
      legend = { displayMode = "list"; placement = "bottom"; showLegend = true; };
      tooltip = { mode = "multi"; sort = "none"; };
    };
  };

  # ═══════════════════════════════════════════════════════════════
  #  Composite builders
  # ═══════════════════════════════════════════════════════════════

  # Standard CPU / Memory / Disk / Network row — reused across 5+ dashboards.
  # Returns a list of 5 panels (1 row + 4 visualizations), spanning y to y+15.
  mkResourceRow = {
    y,
    idBase,
    instance ? ".*",
    job ? "integrations/node_exporter",
    mountpoint ? "/"
  }:
  let
    filter = ''job="${job}",instance=~"${instance}"'';
    usageThresholds = {
      mode = "absolute";
      steps = [
        { color = "green"; value = null; }
        { color = "red"; value = 90; }
      ];
    };
  in [
    (mkRow { title = "Host Resources"; inherit y; id = idBase; })
    (mkTimeseriesPanel {
      title = "CPU Usage";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = usageThresholds;
      fillOpacity = 20;
      gridPos = { h = 7; w = 12; x = 0; y = y + 1; };
      id = idBase + 1;
      targets = [
        (mkPromTarget {
          expr = ''1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",${filter}}[5m]))'';
        })
      ];
    })
    (mkTimeseriesPanel {
      title = "Memory Usage";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = usageThresholds;
      fillOpacity = 20;
      gridPos = { h = 7; w = 12; x = 12; y = y + 1; };
      id = idBase + 2;
      targets = [
        (mkPromTarget {
          expr = ''1 - (node_memory_MemAvailable_bytes{${filter}} / node_memory_MemTotal_bytes{${filter}})'';
        })
      ];
    })
    (mkTimeseriesPanel {
      title = "Disk Usage (${mountpoint})";
      unit = "percentunit"; min = 0; max = 1;
      thresholds = usageThresholds;
      fillOpacity = 20;
      gridPos = { h = 7; w = 12; x = 0; y = y + 8; };
      id = idBase + 3;
      targets = [
        (mkPromTarget {
          expr = ''1 - (node_filesystem_avail_bytes{${filter},mountpoint="${mountpoint}"} / node_filesystem_size_bytes{${filter},mountpoint="${mountpoint}"})'';
          legendFormat = "{{instance}} ${mountpoint}";
        })
      ];
    })
    (mkTimeseriesPanel {
      title = "Network I/O";
      unit = "Bps";
      fillOpacity = 20;
      gridPos = { h = 7; w = 12; x = 12; y = y + 8; };
      id = idBase + 4;
      targets = [
        (mkPromTarget {
          expr = ''rate(node_network_receive_bytes_total{${filter},device="eth0"}[5m])'';
          legendFormat = "{{instance}} rx";
        })
        (mkPromTarget {
          expr = ''rate(node_network_transmit_bytes_total{${filter},device="eth0"}[5m])'';
          legendFormat = "{{instance}} tx";
          refId = "B";
        })
      ];
    })
  ];

  # Auto-layout grid of UP/DOWN stat indicators.
  # `hosts` is a list of { name, label?, expr }.
  mkStatusGrid = { hosts, y ? 0, idBase ? 100, cols ? 6 }:
    imap0 (i: host:
      let
        col = lib.mod i cols;
        row = i / cols;
      in
      mkStatPanel {
        title = host.label or host.name;
        gridPos = { h = 3; w = 24 / cols; x = col * (24 / cols); y = y + row * 3; };
        id = idBase + i;
        thresholds = _thresholds.binary;
        colorMode = "background";
        graphMode = "none";
        targets = [
          (mkPromTarget { expr = host.expr; legendFormat = host.name; })
        ];
      }
    ) hosts;

  # Auto-generate histogram percentile panel (p50/p95/p99).
  mkPercentilePanel = {
    title,
    metric,
    gridPos,
    id ? 0,
    labels ? "",
    unit ? "s",
    percentiles ? [ 0.5 0.95 0.99 ]
  }:
  let
    refIds = [ "A" "B" "C" "D" "E" ];
    labelFilter = if labels != "" then "{${labels}}" else "";
  in
  mkTimeseriesPanel {
    inherit title gridPos id unit;
    targets = imap0 (i: p:
      mkPromTarget {
        expr = ''histogram_quantile(${toString p}, rate(${metric}${labelFilter}[5m]))'';
        legendFormat = "p${toString (builtins.floor (p * 100))}";
        refId = builtins.elemAt refIds i;
      }
    ) percentiles;
  };

  # ═══════════════════════════════════════════════════════════════
  #  Alert builders
  # ═══════════════════════════════════════════════════════════════

  mkAlertRule = {
    uid,
    title,
    expr,
    condition ? "C",
    evaluator ? { type = "lt"; params = [ 1 ]; },
    # Accepted for call-site compatibility but unused: the A query is always
    # instant (single point per series), so any reducer is a no-op.
    reducer ? { type = "last"; },
    noDataState ? "NoData",
    # KeepLast (INFRA-169): a query EXECUTION error — datasource briefly
    # unreachable while the grafana host restarts Loki/Prometheus during a
    # deploy — keeps the rule's previous state instead of flipping every
    # rule to Error at once (the Jul 28 21:19 UTC storm paged the whole
    # catalog on a single grafana restart). Genuine outages still page
    # through the underlying metric and noDataState.
    execErrState ? "KeepLast",
    duration ? "10m",
    annotations ? {},
    labels ? {},
    # Must be a real datasource UID. Grafana 12 rejects empty-string UIDs with
    # a cryptic "Datasource provisioning error: data source not found".
    datasourceUid ? "prometheus"
  }: {
    inherit uid title condition noDataState execErrState annotations labels;
    "for" = duration;
    data = [
      {
        refId = "A";
        relativeTimeRange = { from = 600; to = 0; };
        inherit datasourceUid;
        model = { inherit expr; instant = true; refId = "A"; };
      }
      # `threshold` (not classic_conditions) so the rule stays multi-
      # dimensional: one alert instance per series, carrying the series
      # labels. classic_conditions collapses every series into a single
      # label-less instance, which renders {{ $labels.* }} in annotations
      # as "[no value]" in Slack (INFRA-146).
      {
        refId = condition;
        relativeTimeRange = { from = 0; to = 0; };
        datasourceUid = "__expr__";
        model = {
          refId = condition;
          type = "threshold";
          expression = "A";
          conditions = [{ inherit evaluator; }];
        };
      }
    ];
  };

  mkAlertGroup = {
    name,
    folder ? "Alerts",
    interval ? "1m",
    orgId ? 1,
    rules
  }: {
    inherit orgId name folder interval rules;
  };

  mkContactPoint = { name, receivers }: {
    inherit name receivers;
  };

  mkEmailReceiver = {
    uid,
    addresses,
    singleEmail ? false
  }: {
    inherit uid singleEmail;
    type = "email";
    settings = { inherit addresses singleEmail; };
  };

  mkWebhookReceiver = {
    uid,
    url,
    httpMethod ? "POST"
  }: {
    inherit uid;
    type = "webhook";
    settings = { inherit url httpMethod; };
  };

  # Slack receiver — uses an incoming webhook URL (from SOPS).
  # Optional: recipient (channel override), title/text templates, mentionUsers/Groups.
  mkSlackReceiver = {
    uid,
    url,
    recipient ? "",
    title ? ''{{ template "default.title" . }}'',
    text ? ''{{ template "default.message" . }}'',
    mentionUsers ? "",
    mentionGroups ? "",
    mentionChannel ? ""
  }: {
    inherit uid;
    type = "slack";
    settings = {
      inherit url recipient title text mentionUsers mentionGroups mentionChannel;
    };
  };

  mkNotificationPolicy = {
    receiver,
    groupBy ? [ "alertname" ],
    matchers ? [],
    groupWait ? "30s",
    groupInterval ? "5m",
    repeatInterval ? "4h",
    routes ? []
  }: {
    inherit receiver matchers routes;
    group_by = groupBy;
    group_wait = groupWait;
    group_interval = groupInterval;
    repeat_interval = repeatInterval;
  };

  mkMuteTiming = { name, timeIntervals }: {
    inherit name;
    time_intervals = timeIntervals;
  };

  # ═══════════════════════════════════════════════════════════════
  #  Dashboard builder
  # ═══════════════════════════════════════════════════════════════

  mkDashboard = {
    title,
    uid,
    panels,
    tags ? [],
    description ? "",
    refresh ? "1m",
    # Default read-only: source of truth is the .nix file. Users can "Save as..."
    # to fork into the Grafana DB for experimentation. Override per-dashboard
    # if you actually want ad-hoc edits to the provisioned copy.
    editable ? false,
    schemaVersion ? 39,
    timeFrom ? "now-1h",
    timeTo ? "now",
    templating ? []
  }:
  builtins.toJSON {
    annotations.list = [{
      builtIn = 1;
      datasource = ds.grafana;
      enable = true;
      hide = true;
      iconColor = "rgba(0, 211, 255, 1)";
      name = "Annotations & Alerts";
      type = "dashboard";
    }];
    inherit title uid panels description editable schemaVersion refresh;
    # Auto-prepend "nix-managed" tag so users can filter/identify provisioned dashboards.
    tags = [ "nix-managed" ] ++ tags;
    fiscalYearStartMonth = 0;
    graphTooltip = 0;
    links = [];
    templating.list = templating;
    time = { from = timeFrom; to = timeTo; };
    timepicker = {};
    timezone = "browser";
    version = 1;
  };

  # Query-based dashboard variable (e.g. from label_values(metric, label))
  mkQueryVariable = {
    name,
    query,
    label ? "",
    multi ? true,
    includeAll ? true,
    allValue ? "$__all",
    refresh ? 2,
    datasource ? ds.prometheus
  }: {
    inherit name label multi includeAll datasource;
    current = {
      selected = true;
      text = "All";
      value = allValue;
    };
    definition = query;
    options = [];
    query = { qryType = 1; inherit query; };
    inherit refresh;
    regex = "";
    type = "query";
  };

in {
  inherit
    # Datasource references
    ds;
  # Threshold presets
  thresholds = _thresholds;
  inherit
    # Grid position helpers
    pos
    # Target builders
    mkPromTarget mkLokiTarget mkSqlTarget mkTempoTarget
    # Panel builders
    mkRow mkTimeseriesPanel mkStatPanel mkGaugePanel
    mkTablePanel mkTextPanel mkBarChartPanel
    # Composite builders
    mkResourceRow mkStatusGrid mkPercentilePanel
    # Alert builders
    mkAlertRule mkAlertGroup
    mkContactPoint mkEmailReceiver mkWebhookReceiver mkSlackReceiver
    mkNotificationPolicy mkMuteTiming
    # Dashboard builder
    mkDashboard mkQueryVariable;
}
