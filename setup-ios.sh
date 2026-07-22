#!/usr/bin/env bash
# Set up kbeacon-ota on a connected iOS device.
# Requires macOS with Xcode and Nix installed.
#
# Usage:
#   ./setup-ios.sh

set -euo pipefail

result=$(nix-build nix/ios-device-app.nix)

# Copy nix output to a writable directory (nix store is read-only)
workdir=$(mktemp -d)
cp -r "$result/share/ios/." "$workdir/"
chmod -R u+w "$workdir"

# Generate Xcode project and build
cd "$workdir"
xcodegen generate

# Auto-discover Apple Development team ID from keychain.
# The || true keeps set -e/pipefail from killing the script when grep
# matches nothing, so the empty-TEAM_ID guard below can report it.
TEAM_ID=$(security find-identity -v -p codesigning \
  | grep "Apple Development" \
  | head -1 \
  | sed 's/.*(\(.*\)).*/\1/' \
  || true)
[ -z "$TEAM_ID" ] && echo "No Apple Development signing identity found in keychain" && exit 1
echo "Using team ID: $TEAM_ID"

xcodebuild -scheme Hatter \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    -allowProvisioningUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic

# Install on connected device
# The || true keeps set -e from killing the script when the app is in
# neither location, so the else branch below can point at Xcode.
APP_PATH=$(ls -d "$workdir"/build/Build/Products/Debug-iphoneos/Hatter.app 2>/dev/null \
  || ls -d DerivedData/Build/Products/Debug-iphoneos/Hatter.app 2>/dev/null \
  || true)
if [ -n "$APP_PATH" ]; then
  ios-deploy --bundle "$APP_PATH" || echo "ios-deploy not found, open Xcode to install: open $workdir/Hatter.xcodeproj"
else
  echo "Build succeeded. Open Xcode to deploy: open $workdir/Hatter.xcodeproj"
fi
