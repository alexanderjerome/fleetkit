# Flake checks — fleetkit's acceptance gates. `nix flake check` builds all
# of them; CI should treat them as the merge gate.
#
# Philosophy: every check here proves an end-to-end contract, not a unit.
#   * example-fleet   — the parameter surface is COMPLETE: mkFleet over the
#                       template manifest (documentation-range values only)
#                       assembles a deployable host: fleet eval → hostsJson,
#                       stack IDs, and a full NixOS toplevel derivation.
#                       If a module grows a new required setting and the
#                       template isn't taught about it, this fails.
#   * example-tf-render — the terranix pipeline renders the example fleet's
#                       stacks to valid Terraform JSON without eval errors.
#   * launcher        — the fleet CLI package builds and its module tree
#                       imports (catches broken imports/renames that pure
#                       eval never touches).
#   * docs            — the options documentation site builds with
#                       warningsAreErrors: every option fleetkit declares
#                       carries a description, forever.

{ nixpkgs, mkFleet, sops-nix, disko }:

let
  pkgs = import nixpkgs { system = "x86_64-linux"; };

  example = mkFleet {
    modules = [ ../templates/minimal/fleet ];
    backend = { bucket = "example-tofu"; };
  };

  fleetPkg = pkgs.callPackage ./pkgs/_launcher { };

in {
  example-fleet = pkgs.runCommand "fleetkit-example-check" {
    hostsJson = example.packages.hostsJson;
    exampleToplevelDrv = example.nixosConfigurations.example.config.system.build.toplevel.drvPath;
    stackIds = example.packages.tf-stack-ids;
  } ''
    test -s "$hostsJson"
    test -s "$stackIds"
    echo "example toplevel: $exampleToplevelDrv"
    touch $out
  '';

  # Render every leaf stack of the example fleet to Terraform JSON and
  # sanity-parse it. Catches emitter regressions that host eval misses
  # (the tf-<slug> packages are only built on demand otherwise).
  example-tf-render = pkgs.runCommand "fleetkit-example-tf-render" {
    nativeBuildInputs = [ pkgs.jq ];
    renders = pkgs.lib.attrValues
      (pkgs.lib.filterAttrs (n: _: pkgs.lib.hasPrefix "tf-" n && n != "tf-stack-ids")
        example.packages);
  } ''
    for r in $renders; do
      jq -e 'has("resource") or has("data") or has("provider")' "$r" > /dev/null \
        || { echo "render $r is not Terraform JSON"; exit 1; }
    done
    touch $out
  '';

  # The launcher package builds and every module imports.
  launcher = pkgs.runCommand "fleetkit-launcher-check" {
    nativeBuildInputs = [ fleetPkg ];
  } ''
    fleet --help > /dev/null
    touch $out
  '';

  # The options documentation site builds. nixosOptionsDoc runs with
  # warningsAreErrors = true, so any fleetkit option without a
  # description fails this check.
  docs = import ../docs { inherit pkgs nixpkgs sops-nix disko; };
}
