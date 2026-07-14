#!/usr/bin/env bash
# KBeacon OTA tool emulator UI test.
#
# Drives the real APK on an emulator with netsim virtual Bluetooth and
# a simulated KBeacon fleet (kbeacon_peripheral.py), covering the UI
# under various bluetooth signals. Ordered to use only two scans (see
# the scan-rate note further down):
#
#   Phase 1  render + permissions + adapter: permissions are
#            pre-granted, so the app skips its permission page and
#            renders the scanner directly; adapter reports on.
#   Phase 2  weak signal: threshold 100 dBm (above netsim's fixed +20
#            RSSI), the beacon's advertisement is ignored and the list
#            stays empty (RSSI proximity filter).
#   Phase 3  strong signal + configure + report: threshold -100, the
#            simulated KBeacon (advertising 0x2080 only as service
#            data, like real hardware) is listed while the decoy with
#            a non-KKM address and UUID is not (KKM identity gate on
#            the unfiltered scan); then Configure All runs the full
#            MD5 auth + getPara + cfg write over GATT to set a new
#            advertisement period on the peripheral, and the result is
#            POSTed to the host report server.
#
# Required env vars (set by the emulator-ui.nix harness):
#   ADB, EMULATOR_SERIAL, KBEACON_APK, PACKAGE, ACTIVITY, WORK_DIR,
#   HATTER_TEST_SCRIPTS (hatter's test/ tree, for helpers.sh),
#   BUMBLE_PYTHON (python with bumble), REPORT_PYTHON (plain python3),
#   REPORT_PORT
set -euo pipefail
# shellcheck source=helpers.sh
source "$HATTER_TEST_SCRIPTS/android/helpers.sh"

EXIT_CODE=0
PERIPHERAL_PID=""
REPORT_SERVER_PID=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup_background() {
    for pid in "$PERIPHERAL_PID" "$REPORT_SERVER_PID"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup_background EXIT

# ensure_guest_bluetooth_on
# The netsim-backed adapter is normally on after boot, but the guest
# stack can wedge on a starved emulator (see hatter's
# docs/ble-emulator-simulation.md); a disable/enable cycle recovers it
# on the next run_with_retry attempt.
ensure_guest_bluetooth_on() {
    local bt_on
    bt_on=$("$ADB" -s "$EMULATOR_SERIAL" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r\n')
    if [ "$bt_on" != "1" ]; then
        echo "Bluetooth is off (bluetooth_on=$bt_on), enabling..."
        "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager enable 2>/dev/null || true
        local elapsed=0
        while [ $elapsed -lt 60 ]; do
            bt_on=$("$ADB" -s "$EMULATOR_SERIAL" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r\n')
            if [ "$bt_on" = "1" ]; then
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
    fi
    if [ "$bt_on" != "1" ]; then
        echo "FAIL: guest Bluetooth did not come on"
        return 1
    fi
    echo "Guest Bluetooth is on"
    return 0
}

# set_edittext INDEX VALUE
# Focuses the INDEX-th (0-based) EditText on screen, clears it, and
# types VALUE. Layout order: 0 = adv interval, 1 = RSSI threshold,
# 2 = report URL.
set_edittext() {
    local index="$1"
    local value="$2"
    local dump_file="$WORK_DIR/ui_edittext.xml"
    local dump_ok=0

    for _ in 1 2 3; do
        if "$ADB" -s "$EMULATOR_SERIAL" shell uiautomator dump /data/local/tmp/ui.xml 2>&1 | grep -q "dumped"; then
            "$ADB" -s "$EMULATOR_SERIAL" pull /data/local/tmp/ui.xml "$dump_file" 2>/dev/null
            dump_ok=1
            break
        fi
        sleep 2
    done
    if [ $dump_ok -eq 0 ]; then
        echo "FAIL: could not dump UI for EditText $index"
        EXIT_CODE=1
        return 1
    fi

    local bounds
    bounds=$(grep -o 'class="android.widget.EditText"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' "$dump_file" \
        | sed -n "$((index + 1))p" \
        | grep -o '\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]')
    if [ -z "$bounds" ]; then
        echo "FAIL: EditText $index not found in UI dump"
        EXIT_CODE=1
        return 1
    fi

    local left top right bottom tap_x tap_y
    left=$(echo "$bounds" | sed 's/^\[//;s/,.*//')
    top=$(echo "$bounds" | sed 's/^\[[0-9]*,//;s/\].*//')
    right=$(echo "$bounds" | sed 's/.*\]\[//;s/,.*//')
    bottom=$(echo "$bounds" | sed 's/.*,//;s/\]//')
    tap_x=$(( (left + right) / 2 ))
    tap_y=$(( (top + bottom) / 2 ))
    echo "Typing '$value' into EditText $index at ($tap_x, $tap_y)"
    "$ADB" -s "$EMULATOR_SERIAL" shell input tap "$tap_x" "$tap_y"
    sleep 1
    # Clear whatever is in the field: jump to the end, delete up to 24
    # characters (all our defaults are far shorter).
    "$ADB" -s "$EMULATOR_SERIAL" shell input keyevent KEYCODE_MOVE_END
    for _ in $(seq 1 24); do
        "$ADB" -s "$EMULATOR_SERIAL" shell input keyevent KEYCODE_DEL
    done
    "$ADB" -s "$EMULATOR_SERIAL" shell input text "$value"
    sleep 1
}

# --- Start the virtual KBeacon fleet -------------------------------------
PERIPHERAL_LOG="$WORK_DIR/kbeacon_peripheral.log"
"$BUMBLE_PYTHON" "$(dirname "$0")/kbeacon_peripheral.py" > "$PERIPHERAL_LOG" 2>&1 &
PERIPHERAL_PID=$!
PERIPHERAL_WAIT=0
while [ $PERIPHERAL_WAIT -lt 30 ]; do
    if grep -q "ADVERTISING_STARTED" "$PERIPHERAL_LOG" 2>/dev/null \
        && grep -q "DECOY_ADVERTISING_STARTED" "$PERIPHERAL_LOG" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$PERIPHERAL_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    PERIPHERAL_WAIT=$((PERIPHERAL_WAIT + 1))
done
if ! grep -q "ADVERTISING_STARTED" "$PERIPHERAL_LOG" 2>/dev/null; then
    echo "FAIL: virtual KBeacon fleet did not start advertising"
    cat "$PERIPHERAL_LOG"
    exit 1
fi
echo "Virtual KBeacon fleet is advertising (pid $PERIPHERAL_PID)"

# --- Start the report sink ------------------------------------------------
REPORT_LOG="$WORK_DIR/report_server.log"
"$REPORT_PYTHON" "$(dirname "$0")/report_server.py" "$REPORT_PORT" > "$REPORT_LOG" 2>&1 &
REPORT_SERVER_PID=$!
sleep 1
if ! grep -q "REPORT_SERVER_LISTENING" "$REPORT_LOG" 2>/dev/null; then
    echo "FAIL: report server did not start"
    cat "$REPORT_LOG"
    exit 1
fi

ensure_guest_bluetooth_on || exit 1

# --- Phase 1: install, render, adapter ------------------------------------
# Grant the runtime permissions between install and launch (not via
# start_app, which launches immediately): MainActivity.onCreate fires
# requestPermissions right away, and pre-granting keeps the dialog
# from ever appearing, on every retry attempt.
install_apk "$KBEACON_APK" || { echo "FAIL: install_apk"; exit 1; }
for permission in android.permission.BLUETOOTH_SCAN \
                  android.permission.BLUETOOTH_CONNECT \
                  android.permission.ACCESS_FINE_LOCATION; do
    "$ADB" -s "$EMULATOR_SERIAL" shell pm grant "$PACKAGE" "$permission" 2>/dev/null \
        || echo "WARNING: could not grant $permission"
done
"$ADB" -s "$EMULATOR_SERIAL" logcat -c
"$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE/$ACTIVITY"

wait_for_render "kbeacon"
wait_for_logcat "kbeacon-ota starting" 30 || true
collect_logcat "kbeacon"
assert_logcat "$LOGCAT_FILE" "kbeacon-ota starting" "app main ran"

# The permissions were granted via pm above, so the app probes them
# on its first render and skips the permission page entirely.
wait_for_logcat "permissions already granted" 20 || true
LOGCAT_PERMS="$WORK_DIR/kbeacon_perms.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_PERMS" 2>&1 || true
assert_logcat "$LOGCAT_PERMS" "permissions already granted, skipping the permission page" \
    "permission page skipped when everything is granted"

tap_button "Check Adapter" || echo "WARNING: could not tap Check Adapter"
wait_for_logcat "BLE adapter: BleAdapterOn" 20 || true
LOGCAT_ADAPTER="$WORK_DIR/kbeacon_adapter.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_ADAPTER" 2>&1 || true
assert_logcat "$LOGCAT_ADAPTER" "BLE adapter: BleAdapterOn" "netsim adapter is on"

# The flow uses two scans (weak, then strong). The weak-signal test
# runs first; the strong-signal scan is left running so Configure All
# reuses its device list. Attempts where netsim's guest Bluetooth
# wedges find nothing on either scan (a whole-attempt discovery
# failure, not a scan-rate limit); run_with_retry re-runs the flow and
# cycles the guest stack until a clean attempt lands, so keep the
# attempt budget generous.

# --- Phase 2: weak signal, RSSI threshold filter --------------------------
# netsim reports a fixed +20 dBm RSSI for the virtual peripheral, so a
# threshold of 100 sits above it: the beacon is filtered out and the
# 'ignored' line proves the scan saw it and the RSSI filter dropped it.
set_edittext 1 "100" || true
tap_button "Start Scan" || echo "WARNING: could not tap Start Scan"
wait_for_logcat "ignored FC:57:29:F4:F5:F6" 90 || true
LOGCAT_WEAK="$WORK_DIR/kbeacon_weak.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_WEAK" 2>&1 || true
assert_logcat "$LOGCAT_WEAK" "ignored FC:57:29:F4:F5:F6 rssi=" \
    "advertisement below the threshold is ignored"
if grep -q "found beacon KBPro-F4F5F6" "$LOGCAT_WEAK" 2>/dev/null; then
    echo "FAIL: beacon below the RSSI threshold was still listed"
    EXIT_CODE=1
else
    echo "PASS: beacon below the RSSI threshold stayed out of the list"
fi
tap_button "Stop Scan" || echo "WARNING: could not tap Stop Scan"
# Space the two scans so the second stays under Android's scan-rate limit.
sleep 10

# --- Phase 3: strong signal + UUID filter, then configure -----------------
set_edittext 1 "-100" || true
set_edittext 0 "800" || true
set_edittext 2 "http://10.0.2.2:$REPORT_PORT/report" || true

"$ADB" -s "$EMULATOR_SERIAL" logcat -c 2>/dev/null || true
tap_button "Start Scan" || echo "WARNING: could not tap Start Scan"
wait_for_logcat "found beacon KBPro-F4F5F6" 90 || true
LOGCAT_SCAN="$WORK_DIR/kbeacon_scan.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_SCAN" 2>&1 || true
assert_logcat "$LOGCAT_SCAN" "found beacon KBPro-F4F5F6" \
    "scan lists the simulated KBeacon from its realistic advertisement"
if grep -q "found beacon NotABeacon" "$LOGCAT_SCAN" 2>/dev/null; then
    echo "FAIL: the KKM identity gate let the decoy through"
    EXIT_CODE=1
else
    echo "PASS: decoy with a non-KKM address stayed hidden"
fi
assert_ui_text "Scanning: yes | 1 device(s) found" "UI shows one discovered device"
# Battery 85 travels in the simulated 0x2080 service data and must
# show in the table's battery cell without connecting.
assert_ui_text " | 85" "battery shown from the advertisement"

# Configure All stops the scan internally and reuses the list above,
# so no third scan is started.
tap_button "Configure All" || echo "WARNING: could not tap Configure All"
wait_for_logcat "configuration finished" 120 || true
# The HTTP report completes asynchronously after the session finishes;
# wait for its log line separately so the assert below cannot race it.
wait_for_logcat "report sent (HTTP" 30 || true

LOGCAT_CONFIGURE="$WORK_DIR/kbeacon_configure.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:I' > "$LOGCAT_CONFIGURE" 2>&1 || true
assert_logcat "$LOGCAT_CONFIGURE" "authenticated (reported MTU" \
    "MD5 auth handshake completed"
assert_logcat "$LOGCAT_CONFIGURE" "battery: 85%" \
    "battery percent read from the beacon config"
assert_logcat "$LOGCAT_CONFIGURE" "committed the new advertisement period" \
    "cfg write acknowledged by the beacon"
assert_logcat "$LOGCAT_CONFIGURE" "configured FC:57:29:F4:F5:F6 to 800 ms" \
    "app recorded the configured period"
assert_logcat "$LOGCAT_CONFIGURE" "report sent (HTTP 200)" \
    "HTTP report delivered"
assert_logcat "$LOGCAT_CONFIGURE" "configuration finished" \
    "configuration session completed"

# Host-side proof from the peripheral's own log.
assert_logcat "$PERIPHERAL_LOG" "AUTH_OK" "peripheral accepted the auth proof"
assert_logcat "$PERIPHERAL_LOG" "GET_PARA" "peripheral served its config"
assert_logcat "$PERIPHERAL_LOG" "CFG_ADV_PRD:0:800" \
    "peripheral stored advPrd 800 on slot 0"

# Host-side proof from the report sink.
assert_logcat "$REPORT_LOG" 'REPORT: .*"ok":true' "report body arrived"
assert_logcat "$REPORT_LOG" 'REPORT: .*FC:57:29:F4:F5:F6' "report names the beacon"
assert_logcat "$REPORT_LOG" 'REPORT: .*"advPeriodMs":800' "report carries the period"

assert_ui_text "Status: configuration finished" "UI shows the finished status"

# --- No-crash check ---------------------------------------------------------
LOGCAT_ERRORS="$WORK_DIR/kbeacon_errors.txt"
"$ADB" -s "$EMULATOR_SERIAL" logcat -d '*:E' > "$LOGCAT_ERRORS" 2>&1 || true
if grep -v 'dlerror set to' "$LOGCAT_ERRORS" 2>/dev/null | grep -qE "$FATAL_PATTERNS"; then
    echo "FAIL: fatal crash detected during the kbeacon test"
    grep -E "$FATAL_PATTERNS" "$LOGCAT_ERRORS" | tail -10
    EXIT_CODE=1
else
    echo "PASS: no crash during the kbeacon test"
fi

echo ""
echo "=== peripheral log ==="
cat "$PERIPHERAL_LOG"
echo "=== report server log ==="
cat "$REPORT_LOG"

"$ADB" -s "$EMULATOR_SERIAL" uninstall "$PACKAGE" 2>/dev/null || true

# A failed attempt is often a wedged guest Bluetooth stack; cycle it so
# the next run_with_retry attempt starts fresh.
if [ $EXIT_CODE -ne 0 ]; then
    echo "Cycling guest Bluetooth for the next attempt..."
    "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager disable 2>/dev/null || true
    sleep 5
    "$ADB" -s "$EMULATOR_SERIAL" shell cmd bluetooth_manager enable 2>/dev/null || true
fi

exit $EXIT_CODE
