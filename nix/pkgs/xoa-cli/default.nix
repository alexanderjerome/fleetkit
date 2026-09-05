{ lib
, python3
, sops
}:

# xoa-cli — standalone Xen Orchestra operator CLI (INFRA-172).
#
# Split out of the fleet launcher so that (a) nix config / apply tooling can
# call it without dragging in the whole fleet CLI, and (b) the planned
# MCP endpoint (INFRA-166) has a single package to consume. `fleet xoa …`
# remains a thin shim over this package.

python3.pkgs.buildPythonApplication {
  pname = "xoa-cli";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = with python3.pkgs; [
    setuptools
  ];

  dependencies = with python3.pkgs; [
    click
    rich
    pyyaml
    websocket-client
  ];

  # sops on PATH for the credential fallback (integrations/xen-orchestra
  # from nix/secrets/secrets.yaml) when XOA_URL/XOA_TOKEN aren't in env.
  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ sops ]}"
  ];

  pythonImportsCheck = [ "xoa_cli" ];

  meta = {
    description = "Xen Orchestra operator CLI for fleetkit fleets";
    license = lib.licenses.mit;
    mainProgram = "xoa-cli";
  };
}
