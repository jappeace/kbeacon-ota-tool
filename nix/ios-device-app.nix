# iOS device app: stages hatter's Xcode project with the pre-built
# kbeacon-ota Haskell library, targeting a real iOS device.
#
# Output: $out/share/ios/ containing project.yml, Swift sources, and
# the static library ready for xcodebuild.
#
# Usage (on a Mac): nix-build nix/ios-device-app.nix
{ sources ? import ./sources }:
let
  lib = import "${sources.hatter}/nix/lib.nix" { inherit sources; };
  iosLib = import ./ios.nix { inherit sources; simulator = false; };
in
# Despite its name, hatter's mkSimulatorApp is just the Xcode project
# stager: it copies Swift sources, project.yml and the given static
# library. Device vs simulator is decided by which library ios.nix
# builds (simulator = false above). prrrrrrrrr's ios-device-app.nix
# uses it the same way.
lib.mkSimulatorApp {
  inherit iosLib;
  iosSrc = "${sources.hatter}/ios";
  name = "kbeacon-ota-ios-device";
}
