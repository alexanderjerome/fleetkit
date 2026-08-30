{ lib
, fleetConfig
}:

let
  inherit (lib) concatStrings optionalString;

  mkSssdConf =
    { allowedGroups ? []
    # SSSD domain identifier (an internal label, not a DNS name).
    , sssdDomain ? fleetConfig.ldap.sssd_domain or "fleet"
    , ldapUri ? fleetConfig.ldap.uri
    , baseDn ? fleetConfig.ldap.base_dn
    # /bin/bash suits the Debian dev VMs (sssdConfFor); NixOS has no
    # /bin/bash and sshd refuses logins whose shell is missing
    # ("User X not allowed because shell /bin/bash does not exist") —
    # the NixOS module overrides this (INFRA-190).
    , defaultShell ? "/bin/bash"
    }:
    let
      accessFilter =
        if allowedGroups == []
        then ""
        else let
          filters = map (g: "(memberOf=cn=${g},ou=groups,${baseDn})") allowedGroups;
        in "(|${concatStrings filters})";
    in ''
      [sssd]
      services = nss, pam, ssh
      domains = ${sssdDomain}

      [nss]
      filter_groups = root
      filter_users = root

      [pam]

      [domain/${sssdDomain}]
      id_provider = ldap
      auth_provider = ldap
      access_provider = ldap
      chpass_provider = ldap

      ldap_uri = ${ldapUri}
      ldap_search_base = ${baseDn}
      ldap_user_search_base = ou=users,${baseDn}
      ldap_group_search_base = ou=groups,${baseDn}

      # INFRA-190: the Authentik LDAP outpost rejects anonymous search
      # ("Anonymous BindDN not allowed") — bind as the ldap-bind service
      # account. $SSSD_BIND_PASSWORD substitutes at runtime from the
      # services.sssd.environmentFile SOPS template (never in the store).
      ldap_default_bind_dn = cn=ldap-bind,ou=users,${baseDn}
      ldap_default_authtok = $SSSD_BIND_PASSWORD

      # Authentik publishes LDAP `uid` as the user's opaque unique hash and
      # `cn` as the username — SSSD's default (ldap_user_name = uid) matches
      # nothing, so every lookup returned empty (INFRA-190). Map names to cn.
      ldap_user_name = cn

      ldap_user_ssh_public_key = sshPublicKey
      ${optionalString (accessFilter != "") "ldap_access_filter = ${accessFilter}"}

      # Cache credentials so SSH works during brief LDAP outages
      cache_credentials = true
      entry_cache_timeout = 300

      # Don't enumerate all users — resolve on demand only
      enumerate = false

      # Home directory and shell defaults for LDAP users
      fallback_homedir = /home/%u
      default_shell = ${defaultShell}

      # TLS: Authentik LDAP outpost uses internal CA
      ldap_tls_reqcert = allow
    '';
in
{
  inherit mkSssdConf;
}
