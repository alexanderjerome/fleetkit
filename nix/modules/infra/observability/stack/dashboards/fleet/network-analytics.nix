# Network Analytics — DNS, VPN, HTTPS, DHCP, certificate authority.
#
# Renamed from "Netgate" — future-proofed for additional network services
# (traffic analysis, firewall rules, NAT stats, etc.).
#
# The network tier runs on two fleet hosts (node_exporter instance names):
#   - netcore — Caddy reverse proxy + CoreDNS + Kea DHCP + step-ca
#   - vpn     — Headscale VPN coordination server
# (The old ingress/headscale/router instance names never existed as scraped
# node_exporter instances — corrected in INFRA-128.)
#
{ grafana, panels }:
let
  inst = "netcore|vpn";
in
grafana.mkDashboard {
  title = "Network Analytics";
  uid = "network-analytics";
  tags = [ "network" "dns" "vpn" "dhcp" "tls" "netgate" ];
  refresh = "30s";
  timeFrom = "now-6h";
  panels = [

    # ── DNS (CoreDNS) ────────────────────────────────────────────
    (grafana.mkRow { title = "DNS (CoreDNS)"; y = 0; id = 1; })
    (grafana.mkTimeseriesPanel {
      title = "DNS Queries per Second";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 0; y = 1; };
      id = 2;
      targets = [ (grafana.mkPromTarget { expr = ''sum(rate(coredns_dns_requests_total{job="coredns"}[5m]))''; legendFormat = "qps"; }) ];
    })
    (grafana.mkTimeseriesPanel {
      title = "DNS Queries by Type";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 8; y = 1; };
      id = 3;
      targets = [ (grafana.mkPromTarget { expr = ''sum by (type) (rate(coredns_dns_requests_total{job="coredns"}[5m]))''; legendFormat = "{{type}}"; }) ];
    })
    (grafana.mkTimeseriesPanel {
      title = "DNS Response Codes";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 16; y = 1; };
      id = 4;
      targets = [ (grafana.mkPromTarget { expr = ''sum by (rcode) (rate(coredns_dns_responses_total{job="coredns"}[5m]))''; legendFormat = "{{rcode}}"; }) ];
    })
    (grafana.mkPercentilePanel {
      title = "DNS Request Latency";
      metric = "coredns_dns_request_duration_seconds_bucket";
      labels = ''job="coredns"'';
      gridPos = { h = 6; w = 12; x = 0; y = 7; };
      id = 5;
    })
    (grafana.mkTimeseriesPanel {
      title = "DNS Cache Hit Rate";
      unit = "percentunit"; min = 0; max = 1;
      fillOpacity = 20;
      gridPos = { h = 6; w = 6; x = 12; y = 7; };
      id = 6;
      targets = [
        (grafana.mkPromTarget {
          expr = ''sum(rate(coredns_cache_hits_total{job="coredns"}[5m])) / (sum(rate(coredns_cache_hits_total{job="coredns"}[5m])) + sum(rate(coredns_cache_misses_total{job="coredns"}[5m])))'';
          legendFormat = "hit rate";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "DNS Cache Entries";
      fillOpacity = 20;
      gridPos = { h = 6; w = 6; x = 18; y = 7; };
      id = 7;
      targets = [ (grafana.mkPromTarget { expr = ''coredns_cache_entries{job="coredns"}''; legendFormat = "{{type}}"; }) ];
    })

    # ── VPN (Headscale) ──────────────────────────────────────────
    (grafana.mkRow { title = "VPN (Headscale)"; y = 13; id = 10; })
    (panels.infra.serviceStatus {
      expr = ''up{job=~".*headscale.*"}'';
      gridPos = { h = 4; w = 8; x = 0; y = 14; };
      id = 11;
      title = "Headscale Status";
    })
    (grafana.mkStatPanel {
      title = "Connected VPN Nodes";
      gridPos = { h = 4; w = 8; x = 8; y = 14; };
      id = 12;
      targets = [ (grafana.mkPromTarget { expr = "headscale_nodestore_nodes_total"; legendFormat = "nodes"; }) ];
    })
    # Headscale's metrics endpoint omits the Go process collector, so
    # process_start_time_seconds is unavailable. Fall back to the host's
    # boot time — the `vpn` LXC is dedicated to headscale, so this tracks
    # the service lifetime closely enough.
    (grafana.mkStatPanel {
      title = "Headscale Host Uptime";
      unit = "s";
      gridPos = { h = 4; w = 8; x = 16; y = 14; };
      id = 13;
      targets = [ (grafana.mkPromTarget { expr = ''time() - node_boot_time_seconds{instance="vpn"}''; legendFormat = "uptime"; }) ];
    })

    # ── HTTPS (Caddy) ────────────────────────────────────────────
    (grafana.mkRow { title = "HTTPS (Caddy)"; y = 18; id = 20; })
    (panels.infra.serviceStatus {
      expr = ''up{job=~".*caddy.*"}'';
      gridPos = { h = 4; w = 8; x = 0; y = 19; };
      id = 21;
      title = "Caddy Status";
    })
    (grafana.mkTimeseriesPanel {
      title = "Caddy Request Rate";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 8; y = 19; };
      id = 22;
      targets = [ (grafana.mkPromTarget { expr = "sum by (handler) (rate(caddy_http_requests_total[5m]))"; legendFormat = "{{handler}}"; }) ];
    })
    # Caddy doesn't emit a `caddy_http_responses_total` counter; the
    # canonical source for response codes is the duration histogram's
    # _count series, which carries the `code` label.
    (grafana.mkTimeseriesPanel {
      title = "Caddy Response Codes";
      unit = "reqps";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 16; y = 19; };
      id = 23;
      targets = [ (grafana.mkPromTarget { expr = "sum by (code) (rate(caddy_http_response_duration_seconds_count[5m]))"; legendFormat = "{{code}}"; }) ];
    })

    # ── DHCP (Kea) ───────────────────────────────────────────────
    # Kea emits each address counter twice: once per (subnet, pool) and once
    # per (subnet) with an empty pool label. Filter on pool="" so the panels
    # show one entry per subnet instead of duplicating per-subnet + per-pool.
    (grafana.mkRow { title = "DHCP (Kea)"; y = 25; id = 30; })
    (grafana.mkStatPanel {
      title = "DHCP Active Leases";
      gridPos = { h = 4; w = 12; x = 0; y = 26; };
      id = 31;
      targets = [ (grafana.mkPromTarget { expr = ''kea_dhcp4_addresses_assigned_total{pool=""}''; legendFormat = "{{subnet}}"; }) ];
    })
    (grafana.mkStatPanel {
      title = "DHCP Pool Utilization";
      unit = "percentunit";
      thresholds = grafana.thresholds.usage;
      gridPos = { h = 4; w = 12; x = 12; y = 26; };
      id = 32;
      targets = [
        (grafana.mkPromTarget {
          expr = ''kea_dhcp4_addresses_assigned_total{pool=""} / kea_dhcp4_addresses_total{pool=""}'';
          legendFormat = "{{subnet}}";
        })
      ];
    })

    # ── Certificate Authority (step-ca) ──────────────────────────
    (grafana.mkRow { title = "Certificate Authority (step-ca)"; y = 30; id = 40; })
    (panels.infra.serviceStatus {
      expr = ''up{job=~".*step-ca.*"}'';
      gridPos = { h = 4; w = 8; x = 0; y = 31; };
      id = 41;
      title = "step-ca Status";
    })
    # step-ca exports x509 issuance as a single counter (no provisioner label).
    (grafana.mkTimeseriesPanel {
      title = "Certificates Issued (5m)";
      fillOpacity = 20;
      gridPos = { h = 6; w = 8; x = 8; y = 31; };
      id = 42;
      targets = [ (grafana.mkPromTarget { expr = "increase(step_ca_x509_signed_total[5m])"; legendFormat = "x509 signed"; }) ];
    })
    # step-ca exposes its own uptime gauge — prefer it over host boot time.
    (grafana.mkStatPanel {
      title = "step-ca Uptime";
      unit = "s";
      gridPos = { h = 4; w = 8; x = 16; y = 31; };
      id = 43;
      targets = [ (grafana.mkPromTarget { expr = "step_ca_uptime_seconds"; legendFormat = "uptime"; }) ];
    })

    # ── Network ──────────────────────────────────────────────────
    (grafana.mkRow { title = "Network"; y = 37; id = 50; })
    (panels.infra.networkIO {
      instance = inst;
      deviceMatch = ''device!~"lo|veth.*|br-.*|docker.*"'';
      gridPos = { h = 7; w = 12; x = 0; y = 38; };
      id = 51;
      title = "Network Interface Throughput";
    })
    (grafana.mkTimeseriesPanel {
      title = "Network Errors & Drops";
      fillOpacity = 20;
      gridPos = { h = 7; w = 12; x = 12; y = 38; };
      id = 52;
      targets = [
        (grafana.mkPromTarget {
          expr = ''rate(node_network_receive_errs_total{job="integrations/node_exporter",instance=~"${inst}",device!~"lo|veth.*"}[5m])'';
          legendFormat = "rx errors {{device}}";
        })
        (grafana.mkPromTarget {
          expr = ''rate(node_network_transmit_errs_total{job="integrations/node_exporter",instance=~"${inst}",device!~"lo|veth.*"}[5m])'';
          legendFormat = "tx errors {{device}}";
          refId = "B";
        })
      ];
    })
    (grafana.mkTimeseriesPanel {
      title = "Active TCP Connections";
      fillOpacity = 20;
      gridPos = { h = 6; w = 12; x = 0; y = 45; };
      id = 53;
      targets = [
        (grafana.mkPromTarget {
          expr = ''node_netstat_Tcp_CurrEstab{job="integrations/node_exporter",instance=~"${inst}"}'';
          legendFormat = "established";
        })
      ];
    })

    # ── Host Resources ───────────────────────────────────────────
    (grafana.mkRow { title = "Host Resources (network tier)"; y = 51; id = 60; })
    (panels.infra.cpuUsage    { instance = inst; gridPos = { h = 7; w = 6; x = 0;  y = 52; }; id = 61; })
    (panels.infra.memoryUsage { instance = inst; gridPos = { h = 7; w = 6; x = 6;  y = 52; }; id = 62; })
    (panels.infra.diskUsage   { instance = inst; mountpoint = "/"; gridPos = { h = 7; w = 6; x = 12; y = 52; }; id = 63; })
    (grafana.mkTimeseriesPanel {
      title = "System Load Average";
      fillOpacity = 20;
      gridPos = { h = 7; w = 6; x = 18; y = 52; };
      id = 64;
      targets = [ (grafana.mkPromTarget { expr = ''node_load1{job="integrations/node_exporter",instance=~"${inst}"}''; legendFormat = "load1"; }) ];
    })
  ];
}
