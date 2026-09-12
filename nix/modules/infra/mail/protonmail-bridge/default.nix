# Proton Mail Bridge, headless.
#
# The bridge speaks IMAP/SMTP on loopback and translates to Proton's
# encrypted API, which is the only way a service (or a mail client that
# is not Proton's) can send through a Proton account. Upstream nixpkgs
# ships `services.protonmail-bridge`, but it is a *user* unit wanted by
# `graphical-session.target` — inert on a headless fleet member. This
# module is the system-service equivalent, ported from the Proxmox
# community script (pve-community-nix `legacy/install/protonmail-bridge-install.sh`).
#
# Three things make it awkward, and all three are handled here:
#
#   1. The bridge stores account credentials in `pass`, which needs a GPG
#      key. On a headless host nobody types a passphrase, so the key is
#      generated with an empty one by a oneshot unit. The secret this
#      protects is the bridge's own local copy of the Proton session; the
#      real boundary is filesystem permissions on the state directory.
#   2. **The first login is interactive and is not automated.** Run
#      `protonmail-bridge-login` on the host once; it stops the sockets,
#      drops into the bridge CLI for `login`, and writes the marker that
#      lets the service unit start. Two-factor and the mailbox password
#      are prompts, not options.
#   3. The bridge binds its own listeners to 127.0.0.1 only, with no knob
#      to change that. Reaching it from another host means a proxy, so
#      each exposed port is a systemd socket handing off to
#      `systemd-socket-proxyd`.
#
# The bridge presents a self-signed certificate on both listeners
# (generated at first run, unique per install). A client that validates
# the chain will refuse it — either import `<stateDir>/cert.pem` into
# that client's trust store, or disable verification there.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.mail.protonmailBridge;

  user = "protonbridge";
  stateDir = "/var/lib/protonmail-bridge";

  # Written once the operator has completed the interactive login. The
  # service unit is conditioned on it: a bridge with no account is a
  # listener that authenticates nobody, and starting it would make the
  # SMTP port look alive to Infisical while every message bounced.
  loginMarker = "${stateDir}/.logged-in";

  bridgeEnv = {
    HOME = stateDir;
    GNUPGHOME = "${stateDir}/.gnupg";
    PASSWORD_STORE_DIR = "${stateDir}/.password-store";
  };

  # `runuser -u <user> -- env A=b …` — the bridge and its keyring tools
  # must all agree on HOME, or `pass` and the bridge look at different
  # stores and the login silently fails to persist.
  asBridgeUser = lib.concatStringsSep " " (
    [ "${pkgs.util-linux}/bin/runuser" "-u" user "--" "${pkgs.coreutils}/bin/env" ]
    ++ lib.mapAttrsToList (k: v: "${k}=${v}") bridgeEnv
  );

  # Idempotent: generates the GPG key and initialises the pass store only
  # when they are absent. Runs as root and drops to the bridge user.
  keyringInit = pkgs.writeShellScript "protonmail-bridge-keyring-init" ''
    set -euo pipefail

    install -d -m 0700 -o ${user} -g ${user} "${bridgeEnv.GNUPGHOME}"

    fpr() {
      ${asBridgeUser} ${pkgs.gnupg}/bin/gpg --list-secret-keys --with-colons 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: '$1=="fpr"{print $10; exit}'
    }

    # `|| true`: gpg exits 0 on an empty keyring today, but this runs
    # under `set -e` with a pipeline, so a future non-zero would abort
    # the script instead of falling through to key generation. The
    # empty-fingerprint check below is the real error path.
    FPR="$(fpr || true)"
    if [ -z "$FPR" ]; then
      echo "protonmail-bridge: generating the keyring GPG key"
      ${asBridgeUser} ${pkgs.gnupg}/bin/gpg --batch --pinentry-mode loopback --passphrase "" \
        --quick-gen-key 'Proton Mail Bridge' default default never
      FPR="$(fpr || true)"
    fi

    if [ -z "$FPR" ]; then
      echo "protonmail-bridge: no GPG key fingerprint after generation" >&2
      exit 1
    fi

    if [ ! -f "${bridgeEnv.PASSWORD_STORE_DIR}/.gpg-id" ]; then
      echo "protonmail-bridge: initialising the pass store"
      ${asBridgeUser} ${pkgs.pass}/bin/pass init "$FPR"
    fi

    chown -R ${user}:${user} "${stateDir}"
  '';

  # The one manual step. Deliberately a command an operator runs, not a
  # unit: it is interactive by nature (password, 2FA) and must happen
  # exactly once per account.
  loginScript = pkgs.writeShellScriptBin "protonmail-bridge-login" ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "protonmail-bridge-login must run as root (it drops to ${user})." >&2
      exit 1
    fi

    echo "Stopping the bridge and its proxies — external access is off until this exits."
    systemctl stop ${lib.concatStringsSep " " (proxyUnits "socket")} 2>/dev/null || true
    systemctl stop ${lib.concatStringsSep " " (proxyUnits "service")} protonmail-bridge.service 2>/dev/null || true

    systemctl start protonmail-bridge-keyring.service

    cat <<'MSG'

    In the bridge CLI that follows:
      login   authenticate the Proton account (password, then 2FA)
      info    print the SMTP/IMAP bridge password — this is what services use,
              NOT the Proton account password
      exit    leave the CLI

    MSG

    ${asBridgeUser} ${lib.getExe cfg.package} --cli

    touch "${loginMarker}"
    chown ${user}:${user} "${loginMarker}"

    systemctl start protonmail-bridge.service ${lib.concatStringsSep " " (proxyUnits "socket")}
    echo "Bridge started."
  '';

  # Each exposed port is a (socket, service) pair sharing one name, so
  # systemd links them implicitly.
  proxies = {
    protonmail-bridge-smtp = {
      description = "Proton Mail Bridge SMTP proxy";
      listenPort = cfg.smtp.port;
      targetPort = cfg.smtp.bridgePort;
    };
  } // lib.optionalAttrs cfg.imap.enable {
    protonmail-bridge-imap = {
      description = "Proton Mail Bridge IMAP proxy";
      listenPort = cfg.imap.port;
      targetPort = cfg.imap.bridgePort;
    };
  };

  proxyUnits = suffix: map (n: "${n}.${suffix}") (builtins.attrNames proxies);
in
{
  options.infra.mail.protonmailBridge = {
    enable = mkEnableOption "headless Proton Mail Bridge (IMAP/SMTP gateway to a Proton account)";

    package = mkOption {
      type = types.package;
      default = pkgs.protonmail-bridge;
      defaultText = lib.literalExpression "pkgs.protonmail-bridge";
      description = "Proton Mail Bridge package. The headless build, not the Qt GUI one.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      example = "10.0.0.5";
      description = ''
        Address the socket proxies bind. The bridge itself always listens
        on 127.0.0.1 and cannot be told otherwise, so this is the only
        place the exposure is decided. Set it to 127.0.0.1 to keep the
        bridge host-local; the default serves the fleet, which is the
        point of running it on its own host.
      '';
    };

    logLevel = mkOption {
      type = types.nullOr (types.enum [ "panic" "fatal" "error" "warn" "info" "debug" ]);
      default = null;
      description = "Bridge log level. Null leaves the bridge's own default.";
    };

    smtp = {
      port = mkOption {
        type = types.port;
        default = 587;
        description = "Port the SMTP proxy listens on, for clients and services.";
      };
      bridgePort = mkOption {
        type = types.port;
        default = 1025;
        description = ''
          Loopback port the bridge itself serves SMTP on. Change this only
          to match a bridge whose own setting was moved; it is the proxy's
          upstream, not a listener this module creates.
        '';
      };
    };

    imap = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Expose IMAP as well as SMTP. Turn it off for a send-only
          relay — an Infisical or alerting host has no mailbox to read.
        '';
      };
      port = mkOption {
        type = types.port;
        default = 143;
        description = "Port the IMAP proxy listens on.";
      };
      bridgePort = mkOption {
        type = types.port;
        default = 1143;
        description = "Loopback port the bridge itself serves IMAP on. See smtp.bridgePort.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions =
      let
        loopback = cfg.listenAddress == "127.0.0.1" || cfg.listenAddress == "localhost";
        clash = name: listen: target: {
          assertion = !(loopback && listen == target);
          message = "infra.mail.protonmailBridge.${name}: proxy port ${toString listen} equals the bridge's own port on a loopback listenAddress — the proxy would forward to itself.";
        };
      in
      [
        (clash "smtp" cfg.smtp.port cfg.smtp.bridgePort)
      ] ++ lib.optional cfg.imap.enable
        (clash "imap" cfg.imap.port cfg.imap.bridgePort);

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateDir;
      description = "Proton Mail Bridge service account";
    };
    users.groups.${user} = { };

    # 0700: the pass store under here holds the Proton session. The GPG
    # key that wraps it has an empty passphrase, so these permissions are
    # the whole of the protection.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 ${user} ${user} -"
    ];

    environment.systemPackages = [ cfg.package loginScript ];

    systemd.services = {
      protonmail-bridge-keyring = {
        description = "Initialise the Proton Mail Bridge keyring (GPG + pass)";
        wantedBy = [ "multi-user.target" ];
        before = [ "protonmail-bridge.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = keyringInit;
        };
      };

      protonmail-bridge = {
        description = "Proton Mail Bridge (noninteractive)";
        wantedBy = [ "multi-user.target" ];
        requires = [ "protonmail-bridge-keyring.service" ];
        after = [ "protonmail-bridge-keyring.service" "network-online.target" ];
        wants = [ "network-online.target" ];

        # Until the operator has run protonmail-bridge-login once there is
        # no account, and a running bridge would only fail quietly.
        unitConfig.ConditionPathExists = loginMarker;

        environment = bridgeEnv;
        path = [ pkgs.gnupg pkgs.pass ];

        serviceConfig = {
          Type = "simple";
          User = user;
          Group = user;
          WorkingDirectory = stateDir;
          ExecStart = lib.concatStringsSep " " (
            [ (lib.getExe cfg.package) "--noninteractive" ]
            ++ lib.optionals (cfg.logLevel != null) [ "--log-level" cfg.logLevel ]
          );
          Restart = "always";
          RestartSec = 5;

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ stateDir ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          # AF_NETLINK is not optional: the bridge is Go, and Go's
          # net.Interfaces / resolver path goes through netlink. Dropping
          # it produces a bridge that starts and then cannot resolve
          # Proton's API.
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        };
      };
    } // lib.mapAttrs (_: p: {
      inherit (p) description;
      # No wantedBy: the socket activates it. Requires the bridge so the
      # proxy never accepts a connection it has nowhere to forward.
      requires = [ "protonmail-bridge.service" ];
      after = [ "protonmail-bridge.service" ];
      unitConfig.ConditionPathExists = loginMarker;
      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString p.targetPort}";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        DynamicUser = true;
      };
    }) proxies;

    systemd.sockets = lib.mapAttrs (_: p: {
      description = "${p.description} socket";
      wantedBy = [ "sockets.target" ];
      # Same condition as the service behind it: an unbound port is a
      # clearer failure for a client than a port that accepts and then
      # drops because there is no account yet.
      unitConfig.ConditionPathExists = loginMarker;
      socketConfig = {
        ListenStream = "${cfg.listenAddress}:${toString p.listenPort}";
        Accept = false;
      };
    }) proxies;

    infra.services.protonmail-bridge = {
      port = cfg.smtp.port;
      extraPorts = lib.optional cfg.imap.enable {
        port = cfg.imap.port;
        name = "imap";
        protocol = "imap";
      };
      description = "Proton Mail Bridge — IMAP/SMTP gateway to a Proton account";
      category = "mail";
      tags = [ "mail" "smtp" "imap" ];
      # SMTP and IMAP are not HTTP; there is nothing for Caddy to proxy.
      caddy.enable = false;
    };
  };
}
