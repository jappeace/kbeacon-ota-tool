#!/usr/bin/env bash
set -euo pipefail

adb uninstall com.example.kbeaconpro 2>/dev/null || true
adb install "$(nix-build nix/apk.nix)/kbeacon-ota.apk"
