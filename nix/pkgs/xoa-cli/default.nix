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
#
# buildPythonPackage (not …Application) so the module is IMPORTABLE by other
# packages, not just runnable: the fleet launcher's `tf adopt` resolvers reuse
# xoa_cli.api.XoRpc for JSON-RPC lookups (cloud-config UUIDs, INFRA-274). The
# `[project.scripts]` entry point still installs the `xoa-cli` binary, so
# `nix run .#xoa-cli` and the `fleet xoa` shim are unaffected.

python3.pkgs.buildPythonPackage {
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
