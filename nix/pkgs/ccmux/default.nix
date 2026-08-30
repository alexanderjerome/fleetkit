{ stdenvNoCC, fetchurl }:

# ccmux — TUI for managing AI coding agent sessions over tmux/Tailscale.
# Packaged from upstream release binaries (Go, statically linked — no
# autoPatchelf needed). Previously an imperative `nix profile install`
# from a throwaway flake on the dev server; vendored here so the
# sysadmin-home host (INFRA-170) declares it like everything else.

stdenvNoCC.mkDerivation rec {
  pname = "ccmux";
  version = "0.1.27";

  src = fetchurl {
    url = "https://github.com/skzv/ccmux/releases/download/v${version}/ccmux_linux_amd64.tar.gz";
    hash = "sha256-2NDIWWshKhriEXZRBK9KTkSf91/78avpzhZt0lWdm8k=";
  };

  sourceRoot = ".";
  dontBuild = true;

  installPhase = ''
    install -Dm755 ccmux $out/bin/ccmux
    install -Dm755 ccmuxd $out/bin/ccmuxd
  '';

  meta = {
    description = "TUI for managing AI coding agent sessions over tmux/Tailscale";
    homepage = "https://github.com/skzv/ccmux";
    platforms = [ "x86_64-linux" ];
  };
}
