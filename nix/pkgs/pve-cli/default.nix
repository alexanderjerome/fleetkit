# cv4pve-cli — Corsinvest CLI for Proxmox VE (INFRA-31).
#
# kubectl-style remote CLI for PVE: direct API access (`cv4pve-cli api get
# /cluster/resources`), context switching between clusters (`config add/use`),
# and ~300 aliases for common ops. Used here for read-only cluster inventory
# exploration; mutations still go through terranix (`fleet deploy tf`).
#
# Not in nixpkgs — upstream ships a self-contained .NET single-file binary
# (apphost ELF with the managed bundle APPENDED to the file). That layout
# rules out the usual binary-repack hooks: `strip` truncates the appended
# bundle and autoPatchelfHook's multi-pass rewriting corrupts the bundle
# offset. A single manual patchelf invocation (interpreter + rpath in one
# rewrite) is safe — hence dontStrip + hand-rolled fixup below.
{ stdenv, lib, fetchurl, unzip, patchelf, zlib, icu, openssl }:

stdenv.mkDerivation rec {
  pname = "cv4pve-cli";
  version = "2.2.1";

  src = fetchurl {
    url = "https://github.com/Corsinvest/cv4pve-cli/releases/download/v${version}/cv4pve-cli-linux-x64.zip";
    hash = "sha256-S0A9HGRdmnWNmcj8m6P6w2YR+4yY03TEfi7z2QTksFw=";
  };

  nativeBuildInputs = [ unzip patchelf ];

  # Link-time NEEDED is just libstdc++/glibc; the .NET host additionally
  # dlopens ICU, zlib and OpenSSL at runtime, so they go on the rpath too.
  runtimeLibs = lib.makeLibraryPath [ stdenv.cc.cc.lib zlib icu openssl ];

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;          # strip would cut the appended .NET bundle off
  dontPatchELF = true;       # generic hook does a second rewrite — corrupts

  installPhase = ''
    runHook preInstall
    install -Dm755 cv4pve-cli $out/bin/cv4pve-cli
    patchelf \
      --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
      --set-rpath "$runtimeLibs" \
      $out/bin/cv4pve-cli
    runHook postInstall
  '';

  meta = with lib; {
    description = "Corsinvest CLI for Proxmox VE — remote API access, contexts, aliases";
    homepage = "https://github.com/Corsinvest/cv4pve-cli";
    license = licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cv4pve-cli";
  };
}
