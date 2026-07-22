#!/usr/bin/env bash
# Prepare an Xcode project for kbeacon-ota on a real iOS device.
# The user opens the generated project in Xcode and builds/installs from
# there (device code signing requires the Xcode GUI).
#
# Usage:
#   ./setup-ios.sh

set -euo pipefail

result=$(nix-build nix/ios-device-app.nix)

# Copy nix output to a stable in-repo directory (nix store is read-only)
rm -rf ios-project
cp -r "$result/share/ios/." ios-project/
chmod -R u+w ios-project

# Clear Xcode's DerivedData for Hatter so stale build settings don't persist
find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name 'Hatter-*' -exec rm -rf {} + 2>/dev/null || true

# Generate Xcode project
cd ios-project
xcodegen generate

echo ""
echo "Xcode project ready. Open it with:"
echo "  open ios-project/Hatter.xcodeproj"
echo ""
echo "Then build and install from Xcode (Product → Run)."
