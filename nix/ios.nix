# iOS static library, built via hatter's lib.nix (macOS only).
#
# Builds with native macOS GHC, then patches Mach-O with mac2ios.
# hatter itself is compiled from source inside this build (its src/
# tree is the build's source dir); dependencies come pre-built from
# ios-deps.nix.
#
# Usage (on a Mac):
#   nix-build nix/ios.nix                        # device
#   nix-build nix/ios.nix --arg simulator true   # simulator
{ sources ? import ./sources
, simulator ? false
}:
let
  hatterSrc = import "${sources.hatter}/nix/hatter-src.nix" { inherit sources; };
  lib = import "${sources.hatter}/nix/lib.nix" { inherit sources; };
  consumerCabal2Nix = import ./consumer-cabal2nix.nix;
  iosDeps = import "${sources.hatter}/nix/ios-deps.nix" {
    inherit sources consumerCabal2Nix;
  };
in
lib.mkIOSLib {
  inherit hatterSrc simulator;
  pname = "kbeacon-ota-ios";
  mainModule = ../app/Main.hs;
  crossDeps = iosDeps;
  extraModuleCopy = ''
    mkdir -p KBeacon
    cp ${../src/KBeacon/Json.hs} KBeacon/Json.hs
    cp ${../src/KBeacon/Protocol.hs} KBeacon/Protocol.hs
    cp ${../src/KBeacon/Configure.hs} KBeacon/Configure.hs
    cp ${../src/KBeacon/OtaApp.hs} KBeacon/OtaApp.hs
  '';
}
