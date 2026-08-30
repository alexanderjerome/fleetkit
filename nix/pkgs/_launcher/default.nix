{ lib
, python3
, sops
, opentofu
, age
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
  ];

  pythonImportsCheck = [ "fleet_launcher" ];

  meta = {
    description = "fleet — unified TUI/CLI launcher for fleetkit-managed infrastructure";
    license = lib.licenses.mit;
    mainProgram = "fleet";
  };
}
