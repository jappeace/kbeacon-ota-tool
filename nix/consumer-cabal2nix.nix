# Pre-generated cabal2nix function for the kbeacon-ota library.
# Shared by the Android (cross-deps.nix) and iOS (ios-deps.nix)
# dependency builds so both resolve the same package list.
#
# Only library dependencies: the mobile entry point (app/Main.hs) and
# the KBeacon.* modules are compiled by hatter's lib.nix against the
# package DB this produces.
{ mkDerivation, base, bytestring, containers, cryptohash-md5, lib
, text, time
}:
mkDerivation {
  pname = "kbeacon-ota";
  version = "0.2.0.0";
  # unwitch is deliberately absent even though the library uses it:
  # hatter's cross-deps.nix and ios-deps.nix always add unwitch to the
  # collected package DB (hatterOwnDeps), and listing it here as well
  # makes collect-deps copy the same .conf twice, which fails on the
  # read-only first copy. The cabal file still declares it for the
  # native build.
  libraryHaskellDepends = [
    base bytestring containers cryptohash-md5 text time
  ];
  license = lib.licenses.mit;
}
