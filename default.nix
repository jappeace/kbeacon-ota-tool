# Build the kbeacon-ota Android shared library.
# Uses hatter's cross-compilation infrastructure directly.
#
# Usage:
#   nix-build default.nix           # arm64-v8a (default)
#   nix-build default.nix --argstr androidArch armv7a
{ sources ? import ./nix/sources
, androidArch ? "aarch64"
}:
import "${sources.hatter}/nix/android.nix" {
  inherit sources androidArch;
  mainModule = ./src/Main.hs;
  consumerCabal2Nix =
    { mkDerivation, base, lib, text, containers }:
    mkDerivation {
      pname    = "kbeacon-ota";
      version  = "0.1.0.0";
      libraryHaskellDepends = [ base text containers ];
      license  = lib.licenses.mit;
    };
}
