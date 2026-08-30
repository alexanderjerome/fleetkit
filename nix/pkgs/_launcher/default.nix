{ lib
, python3
, sops
, opentofu
, age
  # The framework ansible tree (playbooks + roles) that ships with
  # fleetkit. Baked into the wrapper as $FLEET_ANSIBLE_DIR so
  # `fleet ansible run` and the env bootstrap can resolve framework
  # playbooks/roles when running from the installed package (outside a
  # fleetkit checkout).
, ansibleTree ? ../../../ansible
  # The framework nix/modules/ tree, baked in as $FLEET_MODULES_DIR so
  # module-adjacent playbooks (nix/modules/**/<name>.yml, e.g.
  # infra/services/builder/attic-rebootstrap.yml) resolve from the
  # installed package too.
, modulesTree ? ../../modules
}:

python3.pkgs.buildPythonApplication {
  pname = "fleet-launcher";
  version = "0.3.0";
  pyproject = true;

  src = ./.;

  build-system = with python3.pkgs; [
    setuptools
  ];

  dependencies = with python3.pkgs; [
    click
    rich
    questionary
    pyyaml
    proxmoxer
    requests
    cryptography   # `sk vaultwarden bootstrap` Bitwarden client crypto (INFRA-100)
  ];

  # Runtime-dep check dropped: optional integrations import lazily. Drop
  # the runtime-deps check so the build doesn't fail; the import only
  # fires if a user actually runs that subcommand.
  dontCheckRuntimeDeps = true;

  # Expose sops, opentofu, and age on PATH so `fleet` works outside nix develop.
  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ sops opentofu age ]}"
    "--set-default FLEET_ANSIBLE_DIR ${ansibleTree}"
    "--set-default FLEET_MODULES_DIR ${modulesTree}"
  ];

  pythonImportsCheck = [ "fleet_launcher" ];

  meta = {
    description = "fleet — unified TUI/CLI launcher for fleetkit-managed infrastructure";
    license = lib.licenses.mit;
    mainProgram = "fleet";
  };
}
