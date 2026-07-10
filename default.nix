# Build the kbeacon-ota Android shared library.
# Uses hatter's cross-compilation infrastructure directly.
#
# Usage:
#   nix-build default.nix           # arm64-v8a (default)
#   nix-build default.nix --argstr androidArch armv7a
{ sources ? import ./nix/sources
, androidArch ? "aarch64"
}:
let
  lib = import "${sources.hatter}/nix/lib.nix" { inherit sources androidArch; };
  # Filtered hatter source so platform-file edits don't bust the
  # cross-compile cache (hatter issue #208).
  hatterSrc = import "${sources.hatter}/nix/hatter-src.nix" { inherit sources; };
  consumerCabal2Nix = import ./nix/consumer-cabal2nix.nix;
  crossDeps = import "${sources.hatter}/nix/cross-deps.nix" {
    inherit sources androidArch consumerCabal2Nix hatterSrc;
  };
in
lib.mkAndroidLib {
  inherit hatterSrc crossDeps;
  pname = "kbeacon-ota-android";
  mainModule = ./app/Main.hs;
  # hatter's lib.nix compiles Main.hs with -c (one-shot), which cannot
  # chase the KBeacon.* source imports. --make compiles them
  # transitively; -no-link because lib.nix runs its own link step with
  # the .o files listed below (same workaround as prrrrrrrrr).
  extraGhcFlags = [ "--make" "-no-link" ];
  extraModuleCopy = ''
    # Remove hatter source files: hatter is pre-compiled in the package
    # DB and leaving them causes "ambiguous module" errors with --make.
    rm -f Hatter.hs
    rm -rf Hatter/

    mkdir -p KBeacon
    cp ${./src/KBeacon/Json.hs} KBeacon/Json.hs
    cp ${./src/KBeacon/Protocol.hs} KBeacon/Protocol.hs
    cp ${./src/KBeacon/Configure.hs} KBeacon/Configure.hs
  '';
  extraLinkObjects = [
    "$(pwd)/KBeacon/Json.o"
    "$(pwd)/KBeacon/Protocol.o"
    "$(pwd)/KBeacon/Configure.o"
  ];
}
