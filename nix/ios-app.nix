# iOS simulator app: stages hatter's Xcode project with the pre-built
# kbeacon-ota Haskell library.
#
# Output: $out/share/ios/ containing project.yml, Swift sources, and
# the static library ready for xcodebuild.
#
# Usage (on a Mac): nix-build nix/ios-app.nix
{ sources ? import ./sources }:
let
  lib = import "${sources.hatter}/nix/lib.nix" { inherit sources; };
  iosLib = import ./ios.nix { inherit sources; simulator = true; };
in
lib.mkSimulatorApp {
  inherit iosLib;
  iosSrc = "${sources.hatter}/ios";
  name = "kbeacon-ota-ios-simulator";
}
