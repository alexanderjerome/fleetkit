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
#   * ansible-syntax   — every framework playbook passes
#                       `ansible-playbook --syntax-check` against the role
#                       tree (catches a broken task file or an undefined
#                       role before a hypervisor run does).
#   * compute-surface-golden — the Terraform JSON rendered for a fixture
#                       fleet that hits every LXC/VM emitter path
#                       (nix/checks/fixtures/compute-surface/) is
#                       byte-identical to the committed goldens
#                       (nix/checks/golden/compute-surface/). A schema or
#                       emitter change must come with an intentional
#                       golden update: nix/checks/update-golden.sh.

{ nixpkgs, mkFleet, sops-nix, disko }:

let
  pkgs = import nixpkgs { system = "x86_64-linux"; };

  example = mkFleet {
    modules = [ ../templates/minimal/fleet ];
    backend = { bucket = "example-tofu"; };
  };

  fleetPkg = pkgs.callPackage ./pkgs/_launcher { };

  golden = mkFleet {
    modules = [ ./checks/fixtures/compute-surface ];
    backend = { bucket = "golden-tofu"; };
  };
  goldenRenders = pkgs.lib.mapAttrs' (n: v: pkgs.lib.nameValuePair (pkgs.lib.removePrefix "tf-" n) v)
    (pkgs.lib.filterAttrs (n: _: pkgs.lib.hasPrefix "tf-" n && n != "tf-stack-ids") golden.packages);
  goldenDir = ./checks/golden/compute-surface;

in {
  # The toplevel drvPath goes through unsafeDiscardOutputDependency: a
  # bare `.drvPath` string carries a "build all outputs" context, which
  # turned this eval gate into a full build of the example NixOS closure
  # (tens of GiB). Instantiating the derivation is what proves the module
  # stack closes; building it proves nothing more about the schema.
  example-fleet = pkgs.runCommand "fleetkit-example-check" {
    hostsJson = example.packages.hostsJson;
    exampleToplevelDrv = builtins.unsafeDiscardOutputDependency
      example.nixosConfigurations.example.config.system.build.toplevel.drvPath;
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

  # Framework playbooks parse and their roles resolve. Syntax-only: no
  # host is contacted (`-i localhost,` satisfies inventory loading).
  ansible-syntax = pkgs.runCommand "fleetkit-ansible-syntax-check" {
    nativeBuildInputs = [ pkgs.ansible ];
    src = ../ansible;
  } ''
    export HOME=$TMPDIR ANSIBLE_LOCAL_TEMP=$TMPDIR ANSIBLE_ROLES_PATH=$src/roles
    printf '[defaults]\nhost_key_checking = False\n' > $TMPDIR/ansible.cfg
    export ANSIBLE_CONFIG=$TMPDIR/ansible.cfg
    for pb in pve pbs developer site; do
      ansible-playbook --syntax-check -i localhost, "$src/playbooks/$pb.yml"
    done
    touch $out
  '';

  # The options documentation site builds. nixosOptionsDoc runs with
  # warningsAreErrors = true, so any fleetkit option without a
  # description fails this check.
  docs = import ../docs { inherit pkgs nixpkgs sops-nix disko; };

  compute-surface-golden = (pkgs.runCommand "fleetkit-compute-surface-golden" {
    nativeBuildInputs = [ pkgs.jq pkgs.diffutils ];
    slugs = pkgs.lib.attrNames goldenRenders;
    renderPaths = pkgs.lib.attrValues goldenRenders;
    inherit goldenDir;
    passthru = {
      renders = goldenRenders;
      slugs = pkgs.lib.concatStringsSep " " (pkgs.lib.attrNames goldenRenders);
    };
  } ''
    set -- $renderPaths
    fail=0
    for slug in $slugs; do
      render=$1; shift
      golden="$goldenDir/$slug.json"
      if [ ! -f "$golden" ]; then
        echo "missing golden $slug.json — run nix/checks/update-golden.sh"; fail=1; continue
      fi
      if ! diff -u <(jq -S . "$golden") <(jq -S . "$render"); then
        echo "render of stack $slug differs from golden — if intended, run nix/checks/update-golden.sh"; fail=1
      fi
    done
    [ "$fail" = 0 ] || exit 1
    touch $out
  '');
}
