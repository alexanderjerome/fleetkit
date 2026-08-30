{ config, lib, ... }:
let
  hostName = config.networking.hostName;
  caddyOwns = config.services.caddy.enable or false;
  internalDomain = config.fleet.settings.domain.internal;
in
{
  # Per-host internal cert for <hostname>.<domain.internal>, acquired via
  # the internal CA's (step-ca) ACME directory. Stored at
  # /var/lib/acme/<host>/ so services that want TLS (postgres SSL, future
  # mTLS clients) can read the cert+key off disk without needing a
  # reverse proxy in front.
  #
  # Skipped on Caddy hosts: Caddy already binds port 80 for its own ACME
  # challenges and issues this cert as part of its declared vhost set.
  config = lib.mkIf (!caddyOwns) {
    security.acme = {
      acceptTerms = true;
      defaults.email = config.fleet.settings.acmeEmail;
      defaults.server = config.fleet.settings.internalCa.acmeDirectory;
      certs."${hostName}.${internalDomain}" = {
        domain = "${hostName}.${internalDomain}";
        listenHTTP = ":80";
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 ];
  };
}
