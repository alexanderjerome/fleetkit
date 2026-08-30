{ config, lib, pkgs, ... }:

# SSSD LDAP authentication via Authentik — enables SSH access for users
# managed in Authentik with group-based per-machine access control.
# Local sysadmin/runner/root accounts (core.nix) remain as fallback.
#
# The sssd.conf string is rendered by ./render.nix, a pure function
# also consumed by the flake's `packages.sssdConfFor.<host>` output so
# Debian dev VMs get identical config via `nix build`.
let
  inherit (lib) mkEnableOption mkOption mkIf types;
  cfg = config.infra.sssd;
  sopsLib = import ../../../../lib/sops.nix { inherit lib; };

  # Phase N: LDAP URI / base DN come from the evaluated fleet module's
  # network options, not shared-config/fleet.json.  fleet.network.nix
  # absorbed every field the JSON file used to carry.
  fleetConfig = { ldap = config.fleet.network.ldap; };
  render = import ./render.nix { inherit lib fleetConfig; };

  sssdConf = render.mkSssdConf {
    inherit (cfg) ldapUri baseDn;
    # NixOS has no /bin/bash — hand LDAP users the system bash instead
    # (sshd rejects logins whose shell is missing).
    defaultShell = "/run/current-system/sw/bin/bash";
    # INFRA-199: the sssd-probe service user (login-only, zero sudo) must be
    # able to SSH into every SSSD host so `sk devtools sssd-test` can exercise
    # the full Authentik→LDAP outpost→SSSD→sshd chain. An empty allowedGroups
    # already means allow-any-authenticated — only append to real restrictions
    # (appending to [] would flip allow-all into probe-only).
    allowedGroups =
      if cfg.allowedGroups == [ ] then [ ]
      else cfg.allowedGroups ++ [ "sssd-probes" ];
  };
in
{
  options.infra.sssd = {
    enable = mkEnableOption "SSSD LDAP authentication via Authentik";

    allowedGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Authentik group names allowed to SSH into this machine.
        Empty list allows any authenticated LDAP user.
        Example: [ "developers" "platform-admins" ]
      '';
    };

    sudoGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Authentik group names whose members get password-required sudo
        on this machine (rendered as security.sudo.extraRules matching
        %<group>). The sudo prompt authenticates against Authentik via
        SSSD/PAM. Empty = no LDAP user gets sudo. Local wheel accounts
        (core.nix) are unaffected. See ADR-028.
        Example: [ "developers" ]
      '';
    };

    ldapUri = mkOption {
      type = types.nullOr types.str;
      default = fleetConfig.ldap.uri;
      description = "URI of the Authentik LDAP outpost. Must be non-null when infra.sssd is enabled (asserted).";
    };

    baseDn = mkOption {
      type = types.nullOr types.str;
      default = fleetConfig.ldap.base_dn;
      description = "LDAP base DN for user/group searches. Must be non-null when infra.sssd is enabled (asserted).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ldapUri != null;
        message = "infra.sssd.enable is set but infra.sssd.ldapUri is null — set fleet.network.ldap.uri (or infra.sssd.ldapUri explicitly).";
      }
      {
        assertion = cfg.baseDn != null;
        message = "infra.sssd.enable is set but infra.sssd.baseDn is null — set fleet.network.ldap.base_dn (or infra.sssd.baseDn explicitly).";
      }
    ];

    # INFRA-190: bind credential for the ldap-bind service account. The env
    # file substitutes $SSSD_BIND_PASSWORD in sssd.conf at service start
    # (systemd.exec semantics), keeping the secret out of the nix store. The
    # SAME SOPS key feeds Authentik's ldap-bind app-password token blueprint,
    # so both sides always agree.
    sops.secrets."services/sssd/bind_password" = sopsLib.mkSecret {
      restartUnits = [ "sssd.service" ];
    };
    sops.templates."sssd-env" = sopsLib.mkTemplate {
      restartUnits = [ "sssd.service" ];
      content = ''
        SSSD_BIND_PASSWORD=${config.sops.placeholder."services/sssd/bind_password"}
      '';
    };

    # SSSD daemon
    services.sssd = {
      enable = true;
      config = sssdConf;
      environmentFile = config.sops.templates."sssd-env".path;
      # SSH keys from LDAP via the nixpkgs integration (INFRA-190): it routes
      # AuthorizedKeysCommand through /run/wrappers, which passes sshd's
      # safe-path check. Pointing sshd straight at the store binary fails
      # 'Unsafe AuthorizedKeysCommand: bad ownership or modes for directory
      # /nix/store' and every LDAP login is silently refused pre-key.
      sshAuthorizedKeysIntegration = true;
    };

    # Auto-create home directories on first SSH login
    security.pam.services.sshd.makeHomeDir = true;

    # Password-required sudo for the named LDAP groups. SSSD resolves the
    # group, so the rule covers every current + future member with no
    # host-side change. NOPASSWD is deliberately omitted (ADR-028): the
    # sudo prompt authenticates against Authentik via SSSD/PAM, limiting
    # the blast radius of a stolen SSH key.
    security.sudo.extraRules = mkIf (cfg.sudoGroups != []) (map (g: {
      groups = [ g ];
      commands = [ { command = "ALL"; options = [ "SETENV" ]; } ];
    }) cfg.sudoGroups);

    # Ensure sssd package is in PATH for AuthorizedKeysCommand
    environment.systemPackages = [ pkgs.sssd ];
  };
}
