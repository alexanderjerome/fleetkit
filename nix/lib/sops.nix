# Shared sops-nix helpers for per-module secret declarations.
#
# Usage (from any module under nix/modules/*/):
#   let sopsLib = import ../../lib/sops.nix { inherit lib; };
#       p = config.sops.placeholder;
#   in { sops.secrets."key/path" = sopsLib.mkSecret { ... }; }
#
# Secrets come from the CONSUMER's sops store: the consumer sets
# `sops.defaultSopsFile` once (its sops scaffold module in
# globalModules); nothing here knows the path.

{ lib }:

{
  # Declare a sops secret from the consumer's default sops file.
  # Optional `owner` + `mode` pass through to sops-nix; the file is
  # deployed under /run/secrets/<path> with those perms. Default owner
  # is root, default mode is sops-nix's default (0400 root:root).
  #
  # `infisical` (default null) marks the secret as developer-facing: pass
  # `sopsLib.mkInfisical { ... }` to have `nix run .#infisical-manifest`
  # emit it into an Infisical upload manifest. The metadata rides on the
  # `infisical` option that nix/modules/infisical-export augments onto every
  # sops.secrets entry; sops-nix ignores it. Omit it = infra-only, the
  # secret never leaves SOPS. Non-destructive: existing callers are
  # unchanged and default to infra-only.
  # `sopsFile` (default null) overrides which encrypted file this secret is
  # read from, instead of the consumer's sops.defaultSopsFile. Null keeps the
  # single-file behaviour, so existing consumers are untouched.
  #
  # This is what makes a SPLIT secret store possible: one file per resource,
  # each encrypted to only the hosts that need it, so a compromised container
  # cannot decrypt the whole fleet. With a single defaultSopsFile every host
  # necessarily holds a key to every secret.
  #
  # Prefer `withFile` below over passing sopsFile at each call site — a
  # module usually reads several secrets from the same file, and repeating
  # the path is how one of them silently ends up pointing at the wrong one.
  mkSecret = { restartUnits ? [], owner ? null, group ? null, mode ? null,
               infisical ? null, sopsFile ? null }:
    { inherit restartUnits; }
    // lib.optionalAttrs (owner != null) { inherit owner; }
    // lib.optionalAttrs (group != null) { inherit group; }
    // lib.optionalAttrs (mode != null)  { inherit mode; }
    // lib.optionalAttrs (infisical != null) { inherit infisical; }
    // lib.optionalAttrs (sopsFile != null) { inherit sopsFile; };

  # Bind mkSecret to one encrypted file:
  #
  #   let s = sopsLib.withFile ../secrets/btc-nodes.yaml;
  #   in { sops.secrets."btc-nodes/mainnet/rpc_password" = s { owner = "bitcoind"; }; }
  #
  # Same arguments as mkSecret; an explicit sopsFile still wins, so a single
  # odd secret can escape the binding without abandoning it.
  withFile = file: args: mkSecret ({ sopsFile = file; } // args);

  # Tag a secret for export into Infisical (the developer-facing read
  # replica). Returns the metadata consumed by the `infisical` sops.secrets
  # option and emitted by `nix run .#infisical-manifest`. The actual value
  # push stays a runtime step (the sync tool reads secrets.yaml + this
  # manifest) — nothing decrypted ever lands in the nix store.
  #
  #   project      Infisical project — the hard access boundary.
  #   folder       Folder path within the project (default "/").
  #   environment  Infisical environment (default "prod").
  #   name         Secret name in Infisical (default: last path segment).
  #   groups       Groups granted read (mapped to Authentik groups).
  mkInfisical = { project, folder ? "/", environment ? "prod", name ? null, groups ? [] }:
    { inherit project folder environment name groups; };

  # Build one entry of the Vaultwarden publish allowlist (INFRA-100) — see
  # nix/fleet/vaultwarden-publish.nix. Each entry maps a SOPS key (whose
  # decrypted VALUE becomes the login password) to a shared Vaultwarden org
  # login item. This is STRUCTURE ONLY (no decrypted values reach the nix
  # store); `nix run .#vaultwarden-manifest` emits it and `fleet vaultwarden sync`
  # reads secrets.yaml + the manifest to `bw`-upsert the item. Opt-in by
  # construction: only keys listed in the allowlist are ever published.
  #
  #   sopsKey     SOPS key whose value is the login password. Required.
  #   name        Vaultwarden item name (the searchable title). Required.
  #   username    Literal login username (default ""). For a secret-valued
  #               username, use `usernameKey` instead.
  #   usernameKey SOPS key whose value is the username (default null).
  #   uri         Login URI for autofill / reference (default null).
  #   collection  Org collection the item lands in (default "SOPS-synced").
  #   notes       Freeform item notes (default null).
  mkVaultwarden = { sopsKey, name, username ? "", usernameKey ? null, uri ? null, collection ? "SOPS-synced", notes ? null }:
    { inherit sopsKey name username collection; }
    // lib.optionalAttrs (usernameKey != null) { inherit usernameKey; }
    // lib.optionalAttrs (uri != null) { inherit uri; }
    // lib.optionalAttrs (notes != null) { inherit notes; };

  # Create a sops template (format-agnostic: env files, TOML, plain text).
  mkTemplate = { content, owner ? "root", mode ? null, restartUnits ? [] }:
    { inherit content owner restartUnits; }
    // lib.optionalAttrs (mode != null) { inherit mode; };
}
