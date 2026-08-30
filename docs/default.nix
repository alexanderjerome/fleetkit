# Options documentation site (mdBook), NixOS-WSL style:
#   nixosOptionsDoc renders every option fleetkit declares to CommonMark,
#   which lands in the mdBook alongside the hand-written pages.
#   `nix build .#docs` → static site in result/.
#
# One NixOS eval covers both option trees: fleet.* (manifest schema) and
# infra.* (service modules). Options declared OUTSIDE this repo (NixOS
# itself, sops-nix, disko) are hidden via transformOptions.visible, and
# declaration links are rewritten to GitHub.

{ pkgs, nixpkgs, sops-nix, disko, lib ? pkgs.lib }:

let
  fleetkitRoot = toString ../.;
  githubBase = "https://github.com/alexanderjerome/fleetkit/blob/main";

  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      ../nix/modules
      ../nix/fleet
      # Minimal host stub so the eval closes.
      {
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        boot.loader.grub.enable = false;
        system.stateVersion = "24.05";
      }
    ];
  };

  isOurs = opt:
    lib.any (d: lib.hasPrefix fleetkitRoot (toString d)) opt.declarations;

  optionsDoc = pkgs.nixosOptionsDoc {
    options = eval.options;
    warningsAreErrors = true;
    transformOptions = opt:
      opt
      // { visible = (opt.visible or true) && isOurs opt; }
      // {
        declarations = map (d:
          let rel = lib.removePrefix (fleetkitRoot + "/") (toString d);
          in if lib.hasPrefix fleetkitRoot (toString d)
             then { name = rel; url = "${githubBase}/${rel}"; }
             else d)
          opt.declarations;
      };
  };

in pkgs.stdenv.mkDerivation {
  name = "fleetkit-docs";
  passthru.optionsJSON = optionsDoc.optionsJSON;
  src = ./.;
  nativeBuildInputs = [ pkgs.mdbook pkgs.python3 ];
  buildPhase = ''
    # Structured chapter tree from the options JSON (one page per
    # option group + generated SUMMARY) — not the flat CommonMark dump.
    python3 generate.py ${optionsDoc.optionsJSON}/share/doc/nixos/options.json src
    mdbook build
  '';
  installPhase = ''
    mv book $out
  '';
}
