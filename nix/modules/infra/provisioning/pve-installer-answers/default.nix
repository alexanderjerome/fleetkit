{ config, lib, pkgs, ... }:

# infra.provisioning.pveInstallerAnswers — HTTP answer-file server for PVE/PBS
# auto-install (INFRA-22).
#
# Replaces the per-host pre-baked ISO renderer in nix/pkgs/_launcher/
# fleet_launcher/pve_install.py. The stock Proxmox installer ISO
# (proxmox-ve_9.1-1.iso for PVE, proxmox-backup-server_*.iso for PBS,
# both already living on the NFS ISO Library SR) is prepared once with
# `proxmox-auto-install-assistant prepare-iso --fetch-from http
# --url <publicUrl>/answer`. At install time, the
# installer POSTs system_info JSON to that URL; we match the system's
# MAC against the declared hosts and return the appropriate answer.toml
# as plain text.
#
# Root passwords: per-host SOPS entries at
# `services/pve-installer-answers/passwords/<hostname>`. The module
# auto-declares the sops.secrets and renders the answer-file config
# via sops.templates — passwords never live in the Nix store.
# Populate via: sk devtools secrets keys add <path> '<sha512-crypt-hash>'.
# Until populated, sops-nix activation fails and the service won't
# start (loud failure, not silent).
#
# Match protocol (per the PVE wiki + the upstream natankeddem/autopve
# reference): the installer's POSTed JSON contains the NICs' MAC
# addresses among other system info. We substring-match each declared
# host's `mac` against the raw POST body — same shape autopve uses,
# avoids parsing the (versioned) system_info schema.

let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.provisioning.pveInstallerAnswers;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };

  # PVE expects the install NIC named by udev as `enx<mac-without-colons>`.
  # The installer's `[network] filter.ID_NET_NAME_MAC` selector resolves
  # to that name; mismatch = "no matching network interface found" and
  # the install aborts.
  macToUdevName = mac:
    "enx" + lib.toLower (lib.replaceStrings [":"] [""] mac);

  hostOpts = types.submodule {
    options = {
      hostname = mkOption {
        type = types.str;
        description = ''
          Short hostname; combined with `domain` for FQDN.
          ALSO used as the lookup key for the root-password SOPS entry
          at `services/pve-installer-answers/passwords/<hostname>`.
        '';
      };
      domain = mkOption {
        type = types.str;
        description = "DNS domain used to build the FQDN.";
      };
      productType = mkOption {
        type = types.enum [ "pve" "pbs" "pmg" ];
        description = ''
          Which Proxmox product the answer is for. Doesn't affect the
          answer.toml schema today (all three share it), but kept
          explicit so future per-product divergences are trivial and
          so log lines say "matched <name> (pbs)" not just "<name>".
        '';
      };
      mac = mkOption {
        type = types.strMatching "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$";
        description = ''
          MAC address of the install NIC, lowercase preferred (the
          matcher lowercases both sides). Substring-matched against
          the installer's POSTed system_info JSON. Must be unique
          across `hosts` or the first match wins.
        '';
      };
      ip = mkOption {
        type = types.str;
        description = "Management IPv4 address (no CIDR suffix).";
      };
      cidr = mkOption {
        type = types.str;
        description = ''
          CIDR notation `<ip>/<prefix>` for the management network.
          E.g., "192.0.2.99/24".
        '';
      };
      gateway = mkOption {
        type = types.nullOr types.str;
        default = config.fleet.network.gateway;
        defaultText = lib.literalExpression "config.fleet.network.gateway";
        description = "Default gateway (the fleet's internal gateway by default). Must be non-null for every declared host (asserted).";
      };
      dns = mkOption {
        type = types.nullOr types.str;
        default = if config.fleet.network.internal_resolvers != [ ]
                  then lib.head config.fleet.network.internal_resolvers else null;
        defaultText = lib.literalExpression "lib.head config.fleet.network.internal_resolvers";
        description = "DNS server (the fleet's internal DNS by default). Must be non-null for every declared host (asserted).";
      };
      rootSshKeys = mkOption {
        type = types.listOf types.str;
        description = ''
          List of authorized SSH keys for root on the freshly-installed
          PVE/PBS host. Typically a singleton with
          fleet.network.sysadmin_ssh_key.
        '';
      };
      installDisk = mkOption {
        type = types.str;
        default = "xvda";
        description = ''
          Block device to install onto. XCP-ng VMs use `xvda`; PVE-on-
          metal would be `sda` or `nvme0n1`. Must match what the kernel
          sees at install time — wrong device aborts the installer
          with "disk in 'disk-selection' not found".
        '';
      };
      filesystem = mkOption {
        type = types.enum [
          "ext4" "xfs"
          "zfs (raid0)" "zfs (raid1)" "zfs (raid10)"
          "zfs (raidz-1)" "zfs (raidz-2)" "zfs (raidz-3)"
          "btrfs (raid0)" "btrfs (raid1)" "btrfs (raid10)"
        ];
        default = "ext4";
        description = "Root filesystem for the install.";
      };
      keyboard = mkOption {
        type = types.str;
        default = "en-us";
        description = "Keyboard layout code written to the answer file's `[global]` section (Proxmox installer layout id, e.g. \"en-us\", \"de\").";
      };
      country = mkOption {
        type = types.str;
        default = "us";
        description = "Two-letter country code written to the answer file's `[global]` section; the installer derives mirror and locale defaults from it.";
      };
      timezone = mkOption {
        type = types.str;
        default = "UTC";
        description = "Timezone written to the answer file's `[global]` section (IANA name, e.g. \"Europe/Madrid\").";
      };
      mailto = mkOption {
        type = types.nullOr types.str;
        default = if config.fleet.settings.domain.base != null
                  then "ops@${config.fleet.settings.domain.base}" else null;
        defaultText = lib.literalExpression ''"ops@''${config.fleet.settings.domain.base}"'';
        description = "Notification address baked into the answer file. Must be non-null for every declared host (asserted).";
      };
      firstBootScript = mkOption {
        type = types.str;
        default = "";
        description = ''
          Shell script body executed once at the host's first boot
          after install. Served at GET /first-boot/<hostname>; the
          installer (via the [first-boot] section in answer.toml)
          downloads the script body, chmods it 0700, executes it once
          as root, then deletes it.

          Empty (default) means no [first-boot] section is emitted in
          this host's answer.toml and the GET endpoint returns 404 for
          this hostname.

          Typical use: install + enable a systemd unit that runs
          growpart + pvresize + lvresize on every boot, so disk
          resizes (via terranix's `useDeploySizes = false` flip) are
          picked up automatically without operator intervention.
        '';
      };
    };
  };

  # Each host's root password lives at this SOPS path. The hostname
  # (which IS the per-host identifier across the module) is the key.
  passwordSopsPath = host:
    "services/pve-installer-answers/passwords/${host.hostname}";

  # Render a single host's answer.toml. The `root-password-hashed`
  # field references the SOPS placeholder so sops-nix substitutes
  # at activation time — the password is never in /nix/store.
  #
  # When `host.firstBootScript` is non-empty, a `[first-boot]` block
  # is appended pointing at this module's GET /first-boot/<hostname>
  # endpoint. Ordering = "network-online" because from-url fetches
  # depend on the install-time-static IP being already up.
  renderAnswerToml = host:
    let
      keysList = lib.concatMapStringsSep ", " (k: ''"${k}"'') host.rootSshKeys;
      fqdn = "${host.hostname}.${host.domain}";
      udevName = macToUdevName host.mac;
      pwPlaceholder = config.sops.placeholder.${passwordSopsPath host};

      # `[first-boot]` block when a script is declared. URL points back
      # at this same server's GET /first-boot/<hostname>.
      hasFirstBoot = host.firstBootScript != "";
      firstBootBlock = lib.optionalString hasFirstBoot ''

        [first-boot]
        source   = "from-url"
        url      = "${cfg.publicUrl}/first-boot/${host.hostname}"
        ordering = "network-online"
      '';
    in ''
      # Generated by infra.provisioning.pveInstallerAnswers for ${host.hostname} (${host.productType})
      # Schema: https://pve.proxmox.com/wiki/Automated_Installation

      [global]
      keyboard             = "${host.keyboard}"
      country              = "${host.country}"
      fqdn                 = "${fqdn}"
      mailto               = "${host.mailto}"
      timezone             = "${host.timezone}"
      root-password-hashed = "${pwPlaceholder}"
      root-ssh-keys        = [ ${keysList} ]
      reboot-on-error      = false

      [network]
      source                 = "from-answer"
      cidr                   = "${host.cidr}"
      dns                    = "${host.dns}"
      gateway                = "${host.gateway}"
      filter.ID_NET_NAME_MAC = "${udevName}"

      [disk-setup]
      filesystem = "${host.filesystem}"
      disk-list  = ["${host.installDisk}"]${firstBootBlock}
    '';

  # JSON shape the Python service consumes at startup. Built as a
  # SOPS template (NOT writeText) so the per-host password
  # placeholders inside `answer` strings get substituted by sops-nix
  # at activation time before the Python service reads the file.
  configJsonContent = builtins.toJSON {
    bind_address = cfg.bindAddress;
    port = cfg.port;
    hosts = map (h: {
      name = "${h.hostname} (${h.productType})";
      hostname = h.hostname;                      # used for GET /first-boot/<hostname> lookup
      mac = lib.toLower h.mac;
      answer = renderAnswerToml h;
      first_boot_script = h.firstBootScript;      # served at GET /first-boot/<hostname>; "" → 404
    }) cfg.hosts;
  };
in
{
  options.infra.provisioning.pveInstallerAnswers = {
    enable = mkEnableOption "PVE auto-install answer-file HTTP server";

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        IP the answer service binds to. Defaults to loopback;
        host configs (netcore) set this to the LAN-facing IP so
        PVE/PBS installers can fetch directly.
      '';
    };

    port = mkOption {
      type = types.int;
      default = 8081;
      description = "TCP port the answer service binds to.";
    };

    publicUrl = mkOption {
      type = types.nullOr types.str;
      default = if config.fleet.settings.domain.internal != null
                then "http://answers.${config.fleet.settings.domain.internal}" else null;
      defaultText = lib.literalExpression ''"http://answers.''${config.fleet.settings.domain.internal}"'';
      description = ''
        Base URL the PVE installer uses to reach this server. Embedded
        into the `[first-boot] url` field in answer.toml so the installed
        host can fetch its per-host first-boot script at
        `<publicUrl>/first-boot/<hostname>`. Default matches an
        `answers.<internal-domain>` ingress on the serving host.
      '';
    };

    hosts = mkOption {
      type = types.listOf hostOpts;
      default = [];
      example = lib.literalExpression ''
        [{
          hostname = "pve-alpha";
          productType = "pve";
          mac = "52:54:00:12:34:56";
          ip = "198.51.100.30";
          cidr = "198.51.100.30/24";
          domain = "example.lan";
        }]
      '';
      description = ''
        List of PVE/PBS hosts the server has answers for. Each entry
        must have a matching SOPS entry at
        `services/pve-installer-answers/passwords/<hostname>` populated
        before deploy — sops-nix activation fails closed otherwise.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicUrl != null;
        message = "infra.provisioning.pveInstallerAnswers.enable is set but publicUrl is null — set fleet.settings.domain.internal (or infra.provisioning.pveInstallerAnswers.publicUrl explicitly).";
      }
      {
        assertion = builtins.all (h: h.gateway != null && h.dns != null && h.mailto != null) cfg.hosts;
        message = "infra.provisioning.pveInstallerAnswers: every declared host needs non-null gateway/dns/mailto — set fleet.network.gateway, fleet.network.internal_resolvers and fleet.settings.domain.base, or override them per host entry.";
      }
    ];

    # System user owns the rendered SOPS template + runs the service.
    # Replaces DynamicUser=true: sops-nix needs a stable owner to grant
    # read access to the template file at /run/secrets/rendered/...
    users.users.pve-installer-answers = {
      isSystemUser = true;
      group = "pve-installer-answers";
      description = "PVE/PBS auto-install answer-file HTTP service";
    };
    users.groups.pve-installer-answers = { };

    # One SOPS secret per host. Restart the service if any password
    # changes — sops-nix re-renders the template, but the running
    # Python process holds the OLD config in memory until restart.
    sops.secrets = lib.listToAttrs (map (h: {
      name = passwordSopsPath h;
      value = sopsLib.mkSecret {
        restartUnits = [ "pve-installer-answers.service" ];
      };
    }) cfg.hosts);

    # Rendered JSON config — placeholders substituted at sops-nix
    # activation time. Lands at /run/secrets/rendered/<name>.
    # restartUnits trips the Python service whenever the template
    # content changes (e.g. first-boot script edits or new hosts) so
    # the running process picks up the new answer/first-boot bodies
    # without manual systemctl-restart.
    sops.templates."pve-installer-answers-config.json" = sopsLib.mkTemplate {
      content = configJsonContent;
      owner = "pve-installer-answers";
      mode = "0440";
      restartUnits = [ "pve-installer-answers.service" ];
    };

    systemd.services.pve-installer-answers = {
      description = "PVE auto-install answer-file HTTP server";
      wantedBy = [ "multi-user.target" ];
      # sops-nix populates /run/secrets/rendered/* during the activation
      # script (NOT a systemd unit), so no after/requires for sops is
      # needed — the file is already in place by the time any service
      # starts. The template's `restartUnits` (auto-set by mkSecret in
      # the listToAttrs block above) handles re-render-on-rotation.
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./server.py} ${
          config.sops.templates."pve-installer-answers-config.json".path
        }";
        Restart = "on-failure";
        RestartSec = "5s";
        User = "pve-installer-answers";
        Group = "pve-installer-answers";
        # Hardening — only need network + read on the rendered template.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        SystemCallFilter = [ "@system-service" "~@privileged" ];
      };
    };
  };
}
