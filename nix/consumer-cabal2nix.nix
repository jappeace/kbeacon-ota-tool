# Pre-generated cabal2nix function for the kbeacon-ota library.
# Shared by the Android (cross-deps.nix) and iOS (ios-deps.nix)
# dependency builds so both resolve the same package list.
#
# Only library dependencies: the mobile entry point (app/Main.hs) and
# the KBeacon.* modules are compiled by hatter's lib.nix against the
# package DB this produces.
{ mkDerivation, base, bytestring, containers, cryptohash-md5, lib
, text, time, unwitch
}:
mkDerivation {
  pname = "kbeacon-ota";
  version = "0.2.0.0";
  libraryHaskellDepends = [
    base bytestring containers cryptohash-md5 text time unwitch
  ];
  license = lib.licenses.mit;
}
