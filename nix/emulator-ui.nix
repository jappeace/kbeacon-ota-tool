# Android emulator UI test for the KBeacon OTA tool.
#
# Boots an API 34 emulator with netsim virtual Bluetooth (the same
# setup as hatter's emulator-all.nix), places a simulated KBeacon
# fleet on the virtual radio via bumble, installs the real APK and
# drives its UI through test/android/kbeacon.sh: scanning under
# strong and weak signals, the service-UUID filter, the full GATT
# configuration handshake and the HTTP result report.
#
# Usage:
#   nix-build nix/emulator-ui.nix -o result-emulator-ui
#   ./result-emulator-ui/bin/test-ui
{ sources ? import ./sources }:
let
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  # Single-arch APK: the API 34 x86_64 emulator translates arm64-v8a.
  kbeaconAndroid = import ../default.nix { inherit sources; androidArch = "aarch64"; };
  hatterLib = import "${sources.hatter}/nix/lib.nix" { inherit sources; };
  kbeaconApk = hatterLib.mkApk {
    sharedLibs = [ { lib = kbeaconAndroid; abiDir = "arm64-v8a"; } ];
    androidSrc = ../android;
    baseJavaSrc = "${sources.hatter}/android/java";
    apkName = "kbeacon-ota.apk";
    name = "kbeacon-ota-apk-emulator";
  };

  # netsim needs an API 33+ image; 34 matches hatter's BLE test job.
  emulatorApiLevel = "34";
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ emulatorApiLevel ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ "x86_64" ];
    cmdLineToolsVersion = "8.0";
  };
  sdk = androidComposition.androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";

  # Python with Google's bumble BLE stack for the virtual peripherals.
  bumblePython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.bumble ]);

  imagePackage = "system-images;android-${emulatorApiLevel};google_apis;x86_64";

  testScripts = builtins.path { path = ../test; name = "kbeacon-test-scripts"; };
  hatterTestScripts = builtins.path {
    path = "${sources.hatter}/test";
    name = "hatter-test-scripts";
  };

in pkgs.stdenv.mkDerivation {
  name = "kbeacon-ota-emulator-ui-test";

  dontUnpack = true;

  buildPhase = ''
    mkdir -p $out/bin

    cat > $out/bin/test-ui << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
export ANDROID_SDK_ROOT="${sdkRoot}"
export ANDROID_HOME="${sdkRoot}"
unset ANDROID_NDK_HOME 2>/dev/null || true
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
AVDMANAGER="${sdk}/bin/avdmanager"
KBEACON_APK="${kbeaconApk}/kbeacon-ota.apk"
PACKAGE="me.jappie.otatool"
ACTIVITY=".MainActivity"
DEVICE_NAME="kbeacon_ui"
TEST_SCRIPTS="${testScripts}"
HATTER_TEST_SCRIPTS="${hatterTestScripts}"
BUMBLE_PYTHON="${bumblePython}/bin/python3"
REPORT_PYTHON="${pkgs.python3}/bin/python3"
REPORT_PORT=8977

# --- KVM detection ---
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo "KVM detected -- using hardware acceleration"
    ACCEL_FLAG=""
    BOOT_TIMEOUT=180
else
    echo "No KVM -- using software emulation (slow boot expected)"
    ACCEL_FLAG="-no-accel"
    BOOT_TIMEOUT=900
fi

# --- Temp dirs ---
WORK_DIR=$(mktemp -d /tmp/kbeacon-emu-XXXX)
export HOME="$WORK_DIR/home"
export ANDROID_USER_HOME="$WORK_DIR/user-home"
export ANDROID_AVD_HOME="$WORK_DIR/avd"
export ANDROID_EMULATOR_HOME="$WORK_DIR/emulator-home"
export TMPDIR="$WORK_DIR/tmp"
# netsimd publishes its gRPC port in netsim.ini inside this directory;
# bumble discovers it there. Pin XDG_RUNTIME_DIR so both agree.
export XDG_RUNTIME_DIR="$WORK_DIR/tmp"
mkdir -p "$HOME" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME" "$TMPDIR"

"$ADB" kill-server 2>/dev/null || true
"$ADB" start-server 2>/dev/null || true

EMU_PID=""
PORT=""

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    if [ -n "$EMU_PID" ] && kill -0 "$EMU_PID" 2>/dev/null; then
        kill "$EMU_PID" 2>/dev/null || true
        wait "$EMU_PID" 2>/dev/null || true
    fi
    if [ -n "$PORT" ]; then
        "$ADB" -s "emulator-$PORT" emu kill 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
    echo "Cleanup done."
}
trap cleanup EXIT

# --- Find free port ---
for p in $(seq 5554 2 5584); do
    if ! "$ADB" devices 2>/dev/null | grep -q "emulator-$p"; then
        PORT=$p
        break
    fi
done
if [ -z "$PORT" ]; then
    echo "ERROR: no free emulator port found (5554-5584 all in use)"
    exit 1
fi
echo "Using port: $PORT"
export ANDROID_SERIAL="emulator-$PORT"
EMULATOR_SERIAL="emulator-$PORT"

# --- Create AVD ---
echo "n" | "$AVDMANAGER" create avd \
    --force \
    --name "$DEVICE_NAME" \
    --package "${imagePackage}" \
    --device "pixel_6" \
    -p "$ANDROID_AVD_HOME/$DEVICE_NAME.avd"

cat >> "$ANDROID_AVD_HOME/$DEVICE_NAME.avd/config.ini" << 'AVDCONF'
hw.ramSize = 6144
hw.gpu.enabled = yes
hw.gpu.mode = swiftshader_indirect
disk.dataPartition.size = 2G
AVDCONF

SYSIMG_DIR="$ANDROID_SDK_ROOT/system-images/android-${emulatorApiLevel}/google_apis/x86_64"
if [ ! -d "$SYSIMG_DIR" ]; then
    FOUND_SYSIMG=$(find "$ANDROID_SDK_ROOT" -name "system.img" -print -quit 2>/dev/null || echo "")
    if [ -n "$FOUND_SYSIMG" ]; then
        SYSIMG_DIR=$(dirname "$FOUND_SYSIMG")
        sed -i "s|^image.sysdir.1=.*|image.sysdir.1=$SYSIMG_DIR/|" "$ANDROID_AVD_HOME/$DEVICE_NAME.avd/config.ini"
        echo "Patched image.sysdir.1 to $SYSIMG_DIR"
    else
        echo "ERROR: could not find system.img anywhere in the SDK"
        exit 1
    fi
fi

# --- Boot emulator with netsim virtual Bluetooth ---
"$EMULATOR" \
    -avd "$DEVICE_NAME" \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -no-metrics \
    -port "$PORT" \
    -gpu swiftshader_indirect \
    -no-snapshot \
    -memory 6144 \
    $ACCEL_FLAG \
    -packet-streamer-endpoint default \
    &
EMU_PID=$!
echo "Emulator PID: $EMU_PID"

echo "=== Waiting for boot (timeout: ''${BOOT_TIMEOUT}s) ==="
BOOT_DONE=""
ELAPSED=0
while [ $ELAPSED -lt $BOOT_TIMEOUT ]; do
    BOOT_DONE=$("$ADB" -s "emulator-$PORT" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || echo "")
    if [ "$BOOT_DONE" = "1" ]; then
        echo "Boot completed after ~''${ELAPSED}s"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
if [ "$BOOT_DONE" != "1" ]; then
    echo "ERROR: emulator failed to boot within ''${BOOT_TIMEOUT}s"
    exit 1
fi

echo "Waiting for the package manager..."
SETTLE_ELAPSED=0
while [ $SETTLE_ELAPSED -lt 30 ]; do
    if "$ADB" -s "$EMULATOR_SERIAL" shell pm list packages 2>/dev/null | grep -q "package:"; then
        break
    fi
    sleep 2
    SETTLE_ELAPSED=$((SETTLE_ELAPSED + 2))
done

export ADB EMULATOR_SERIAL KBEACON_APK PACKAGE ACTIVITY WORK_DIR
export HATTER_TEST_SCRIPTS BUMBLE_PYTHON REPORT_PYTHON REPORT_PORT

# run_with_retry LABEL COMMAND [ARGS...]
# Same policy as hatter's emulator harness (retryable-crash.sh aborts
# immediately on a deterministic native failure), but a lower attempt
# cap: this is one self-contained flow, not hatter's whole suite, so a
# persistent failure should surface in minutes. Each attempt cycles
# the guest Bluetooth stack, which also resets Android's scan-rate
# counter between attempts.
run_with_retry() {
    local label="$1"; shift
    local max_attempts=4
    local attempt=1
    local output_file="$WORK_DIR/retry_''${label}.log"
    while [ $attempt -le $max_attempts ]; do
        echo "[$label] attempt $attempt/$max_attempts"
        "$ADB" -s "$EMULATOR_SERIAL" shell am force-stop "$PACKAGE" 2>/dev/null || true
        "$ADB" -s "$EMULATOR_SERIAL" logcat -c 2>/dev/null || true
        if "$@" 2>&1 | tee "$output_file"; then
            echo "[$label] PASSED on attempt $attempt"
            return 0
        fi
        if grep -q "^FATAL:" "$output_file" 2>/dev/null; then
            if bash "$HATTER_TEST_SCRIPTS/android/retryable-crash.sh" "$output_file"; then
                echo "[$label] transient crash (ndk_translation flake), retrying"
            else
                echo "[$label] deterministic native failure, not retrying"
                return 1
            fi
        fi
        echo "[$label] attempt $attempt FAILED"
        attempt=$((attempt + 1))
    done
    echo "[$label] FAILED after $max_attempts attempts"
    return 1
}

echo ""
echo "--- kbeacon UI test ---"
if run_with_retry "kbeacon" bash "$TEST_SCRIPTS/android/kbeacon.sh"; then
    echo ""
    echo "KBEACON UI TEST PASSED"
    exit 0
else
    echo ""
    echo "KBEACON UI TEST FAILED"
    exit 1
fi
SCRIPT

    chmod +x $out/bin/test-ui
  '';

  installPhase = "true";
}
