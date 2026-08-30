# xo-grafana-exporter (INFRA-40) — Prometheus exporter for the XCP-ng
# tier, polling the Xen Orchestra REST API live at scrape time.
#
# Exists because our XOA edition lacks the official OpenMetrics plugin
# and we hold no dom0 credentials — XO REST is the only metrics surface.
# Stdlib-only on purpose: zero python dependencies to chase.
{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "xo-grafana-exporter";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = with python3.pkgs; [
    setuptools
  ];

  pythonImportsCheck = [ "xo_grafana_exporter" ];

  meta = {
    description = "Prometheus exporter for XCP-ng via the Xen Orchestra REST API";
    license = lib.licenses.mit;
    mainProgram = "xo-grafana-exporter";
  };
}
