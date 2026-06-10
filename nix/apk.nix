# Multi-arch APK: arm64-v8a + armeabi-v7a.
# Mirrors the shape of hatter's own nix/apk.nix.
#
# Usage: nix-build nix/apk.nix
{ sources ? import ./sources }:
let
  hatterLib    = import "${sources.hatter}/nix/lib.nix" { inherit sources; };
  sharedAarch64 = import ../default.nix { inherit sources; androidArch = "aarch64"; };
  sharedArmv7a  = import ../default.nix { inherit sources; androidArch = "armv7a"; };
in
hatterLib.mkApk {
  sharedLibs = [
    { lib = sharedAarch64; abiDir = "arm64-v8a"; }
    { lib = sharedArmv7a;  abiDir = "armeabi-v7a"; }
  ];
  androidSrc = "${sources.hatter}/android";
  apkName    = "kbeacon-ota.apk";
  name       = "kbeacon-ota-apk";
}
