# Native (desktop) build: compiles the library, the app and the unit
# tests with hatter's desktop C stubs, and runs the test suite.
#
# Usage: nix-build nix/native.nix
{ sources ? import ./sources }:
let
  pkgs = import sources.nixpkgs {};
  # hatter's own haskellPackages overlay (hatter-project + unwitch),
  # evaluated against the hatter pin so the derivation matches what
  # hatter's CI builds (and what nix-cache.jappie.me has cached).
  hpkgs = import "${sources.hatter}/nix/hpkgs.nix" {};
  kbeaconSrc = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../src
      ../app
      ../test
      ../kbeacon-ota.cabal
    ];
  };
  extended = hpkgs.extend (self: _super: {
    kbeacon-ota = self.callCabal2nix "kbeacon-ota" kbeaconSrc {
      hatter = self.hatter-project;
    };
  });
in
extended.kbeacon-ota
