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

  # A second fleet namespace on the same estate (ADR-097): synthetic
  # tenant sharing the example's provider instance. NOT in the template
  # (a fresh consumer starts single-fleet); declared inline so the check
  # suite exercises the multi-fleet lift end to end.
  tenantModule = {
    config.fleet.fleets.tenant2 = {
      description = "synthetic second fleet for the check suite";
      providers.proxmox.main.nodes.pve1.resources.lxc.tenant2-app = {
        env = "dev"; stack = "core";
        vm_id = 9102;
        tags = [ "tenant2" ];
        ip = ""; internal_ip = "192.0.2.202";
        cpu_cores = 1; memory_mb = 256; swap_mb = 0;
        root_disk_datastore = "local-lvm";
        network_mode = "single-internal";
        notes = "check-suite tenant machine";
      };
    };
  };

  example = mkFleet {
    modules = [ ../templates/minimal/fleet tenantModule ];
    # No backend argument — deliberately: proves the ADR-097 fallback to
    # fleet.settings.backend (the template declares the bucket there).
  };

  # Negative test: the SAME resource name in two fleet namespaces must be
  # a hard eval error (names are estate-global). tryEval + deepSeq —
  # nothing short of forcing the value would trip it (the four
  # green-check-over-broken-code lessons).
  collisionEval = nixpkgs.lib.evalModules {
    modules = [
      ./fleet
      { _module.args.fleetLib =
          import ./lib/module-args.nix { lib = nixpkgs.lib; inherit pkgs; }; }
      ../templates/minimal/fleet tenantModule {
      config.fleet.fleets.rogue.providers.proxmox.main.nodes.pve1.resources.lxc.tenant2-app = {
        env = "dev"; stack = "core"; vm_id = 9103;
        ip = ""; internal_ip = "192.0.2.203";
      };
    } ];
  };
  collisionCaught =
    !(builtins.tryEval
        (builtins.deepSeq collisionEval.config.fleet.compute true)).success;

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
    # v2 path forced end-to-end (ADR-096): the v2-authored host's closure,
    # plus eval-time assertions on the lift. Four times on the consumer
    # port a green check sat over broken code because nothing FORCED the
    # value — these are all strict env attrs, so instantiating this
    # derivation forces every one.
    exampleV2ToplevelDrv = builtins.unsafeDiscardOutputDependency
      example.nixosConfigurations.example-v2.config.system.build.toplevel.drvPath;
    v2Lift = builtins.toJSON {
      kind = example.fleetEval.compute.example-v2.kind;                      # "container"
      node = example.fleetEval.compute.example-v2.node;                      # "pve1"
      pi   = example.fleetEval.compute.example-v2.provider_instance;         # "proxmox.main"
      secretHosts = example.fleetEval.secrets.example-v2.consumers.hosts;    # [ "example-v2" ]
      sopsKey = example.nixosConfigurations.example-v2.config
        .sops.secrets."example-v2/default/api_token".key;                    # "default/api_token"
    };
    # Multi-fleet lift (ADR-097): the tenant machine lands in the flat
    # layer tagged with its namespace, its stack enumerates
    # fleet-prefixed (⇒ namespaced state key), and a cross-namespace
    # name collision is a hard eval error.
    fleetsLift = builtins.toJSON {
      tenantNs    = example.fleetEval.compute.tenant2-app.fleet_ns;   # "tenant2"
      tenantScope = example.fleetEval.compute.tenant2-app.scope;      # "fleet" (default)
      tenantStack = builtins.hasAttr "tenant2.dev.core" example.fleetEval.stacks;
      incumbentUnprefixed = builtins.hasAttr "platform.core" example.fleetEval.stacks;
      inherit collisionCaught;
    };

    # The CLI catalog (ADR-097): force it as a strict env attr and assert
    # the settings→catalog projection (bucket via the settings fallback,
    # toml-era dotted keys present).
    catalog = builtins.readFile "${example.packages.fleet-catalog}";
    passAsFile = [ "v2Lift" "catalog" "fleetsLift" ];
  } ''
    test -s "$hostsJson"
    test -s "$stackIds"
    echo "example toplevel: $exampleToplevelDrv"
    echo "v2 toplevel:      $exampleV2ToplevelDrv"
    grep -q '"kind":"container"' "$v2LiftPath"
    grep -q '"node":"pve1"' "$v2LiftPath"
    grep -q '"sopsKey":"default/api_token"' "$v2LiftPath"
    grep -q '"secretHosts":\["example-v2"\]' "$v2LiftPath"
    grep -q '"bucket":"REPLACE-ME-tofu"' "$catalogPath"
    grep -q '"extensions_dir":"cli-ext"' "$catalogPath"
    grep -q '"secrets_file":"nix/secrets/secrets.yaml"' "$catalogPath"
    grep -q '"tenantNs":"tenant2"' "$fleetsLiftPath"
    grep -q '"tenantScope":"fleet"' "$fleetsLiftPath"
    grep -q '"tenantStack":true' "$fleetsLiftPath"
    grep -q '"incumbentUnprefixed":true' "$fleetsLiftPath"
    grep -q '"collisionCaught":true' "$fleetsLiftPath"
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
