{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.step-ca;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };

  # NixOS step-ca module uses StateDirectory = "step-ca" → /var/lib/step-ca
  stateDir = "/var/lib/step-ca";

  # Auto-init script: runs `step ca init` if certs don't exist yet.
  autoInitScript = pkgs.writeShellScript "step-ca-auto-init" ''
    set -euo pipefail
    CERT="${stateDir}/certs/intermediate_ca.crt"
    if [ -f "$CERT" ]; then
      echo "step-ca: certs already exist, skipping init"
      # Always fix ownership — db/ may have been created by root on a prior run.
      chown -R step-ca:step-ca "${stateDir}"
      exit 0
    fi

    echo "step-ca: first run — bootstrapping PKI..."

    export STEPPATH="${stateDir}"
    ${pkgs.step-cli}/bin/step ca init \
      --name="${cfg.caName}" \
      --dns="${lib.concatStringsSep "," ([ cfg.domain "localhost" ])}" \
      --address="${cfg.address}:${toString cfg.port}" \
      --provisioner="${cfg.provisioner}" \
      --password-file="${config.sops.secrets."services/step-ca/intermediate_password".path}" \
      --deployment-type=standalone

    # step ca init generates its own ca.json — remove it so step-ca
    # uses the NixOS-managed /etc/smallstep/ca.json instead.
    rm -f "${stateDir}/config/ca.json"
    rm -f "${stateDir}/config/defaults.json"
    rmdir "${stateDir}/config" 2>/dev/null || true
    rm -f "${stateDir}/templates/certs/"* 2>/dev/null || true
    rmdir "${stateDir}/templates/certs" 2>/dev/null || true
    rmdir "${stateDir}/templates" 2>/dev/null || true

    # Auto-init runs as root (+prefix) — fix ownership so step-ca user can read.
    chown -R step-ca:step-ca "${stateDir}"

    echo "step-ca: PKI bootstrap complete"
  '';
in
{
  options.infra.step-ca = {
    enable = mkEnableOption "Smallstep step-ca internal ACME server";

    address = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address step-ca listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 9000;
      description = "Port step-ca listens on.";
    };

    metricsPort = mkOption {
      type = types.port;
      default = 2400;
      description = ''
        Port for the Prometheus metrics listener. step-ca exposes
        /metrics on a separate plain-HTTP listener (not the main HTTPS
        API port). Bound to 127.0.0.1 so it isn't reachable off-host.
      '';
    };

    domain = mkOption {
      type = types.str;
      default = "ca.${config.fleet.settings.domain.internal}";
      defaultText = lib.literalExpression ''"ca.''${config.fleet.settings.domain.internal}"'';
      description = "FQDN for the CA server.";
    };

    caName = mkOption {
      type = types.str;
      default = "${config.fleet.settings.name} Internal CA";
      defaultText = lib.literalExpression ''"''${config.fleet.settings.name} Internal CA"'';
      description = "Human-readable name for the Certificate Authority.";
    };

    provisioner = mkOption {
      type = types.str;
      default = "acme";
      description = "Default provisioner name.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.step-cli ];

    sops.secrets."services/step-ca/intermediate_password" = sopsLib.mkSecret {
      restartUnits = [ "step-ca.service" ];
    };

    services.step-ca = {
      enable = true;
      address = cfg.address;
      port = cfg.port;
      openFirewall = true;
      intermediatePasswordFile = config.sops.secrets."services/step-ca/intermediate_password".path;
      settings = {
        root = "${stateDir}/certs/root_ca.crt";
        federatedRoots = null;
        crt = "${stateDir}/certs/intermediate_ca.crt";
        key = "${stateDir}/secrets/intermediate_ca_key";
        address = "${cfg.address}:${toString cfg.port}";
        dnsNames = [ cfg.domain "localhost" ];
        logger.format = "text";
        db = {
          type = "badgerv2";
          dataSource = "${stateDir}/db";
        };
        authority = {
          provisioners = [{
            type = "ACME";
            name = cfg.provisioner;
          }];
        };
        tls = {
          cipherSuites = [
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
          ];
          minVersion = 1.2;
          maxVersion = 1.3;
          renegotiation = false;
        };
        # Prometheus metrics endpoint (plain HTTP, /metrics).
        # Bind to 127.0.0.1 so only the local Alloy can scrape it.
        # step-ca v0.29.0 expects the JSON key `metricsAddress` (flat,
        # camelCase) — `metrics.address` is silently ignored.
        metricsAddress = "127.0.0.1:${toString cfg.metricsPort}";
      };
    };

    # The upstream NixOS module sets DynamicUser=true, but our auto-init script
    # runs as root (+prefix) and chowns to the static step-ca user. DynamicUser
    # allocates a different UID, causing permission denied on /var/lib/step-ca/db.
    systemd.services.step-ca.serviceConfig = {
      DynamicUser = lib.mkForce false;
      ExecStartPre = [ "+${autoInitScript}" ];
      # Make the root CA cert readable by other services (e.g., Caddy ACME).
      # The root CA is a public certificate — safe to be world-readable.
      ExecStartPost = [
        "+${pkgs.coreutils}/bin/chmod 0755 ${stateDir}/certs"
        "+${pkgs.coreutils}/bin/chmod 0644 ${stateDir}/certs/root_ca.crt"
      ];
    };

    users.users.step-ca = {
      isSystemUser = true;
      group = "step-ca";
      home = stateDir;
    };
    users.groups.step-ca = { };

    # Ship step-ca metrics to Prometheus via Alloy.
    # step-ca exposes /metrics on a separate plain-HTTP listener
    # (cfg.metricsPort), not the main HTTPS API port — scraping the
    # API port returns 404.
    infra.alloy.extraConfig = ''

      // ── step-ca certificate authority metrics ───────
      prometheus.scrape "step_ca" {
        targets = [
          {"__address__" = "127.0.0.1:${toString cfg.metricsPort}"},
        ]
        forward_to = [prometheus.remote_write.default.receiver]
        scrape_interval = "30s"
        job_name = "step-ca"
      }
    '';
  };
}
