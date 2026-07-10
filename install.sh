#!/usr/bin/env bash
set -euo pipefail

package=me.jappie.otatool

adb uninstall "$package" 2>/dev/null || true
adb install "$(nix-build nix/apk.nix)/kbeacon-ota.apk"

# Start fresh, then launch the app so there is a process to attach to.
adb logcat -c
adb shell am start -n "$package/.MainActivity"

# pidof returns nothing until the process is up, so poll briefly.
pid=""
for _ in $(seq 1 50); do
  pid=$(adb shell pidof -s "$package" | tr -d '\r')
  [ -n "$pid" ] && break
  sleep 0.1
done

if [ -z "$pid" ]; then
  echo "install.sh: no running process for $package (did it crash on launch?)" >&2
  exit 1
fi

exec adb logcat --pid="$pid"
