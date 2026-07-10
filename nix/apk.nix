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
  # Our own manifest/MainActivity in package me.jappie.otatool. HatterActivity
  # (the JNI base class) is pulled in from hatter via baseJavaSrc; it must keep
  # its own me.jappie.hatter package so libhatter.so's native symbols resolve.
  androidSrc  = ../android;
  baseJavaSrc = "${sources.hatter}/android/java";
  apkName     = "kbeacon-ota.apk";
  name        = "kbeacon-ota-apk";
}
