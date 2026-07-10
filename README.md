# KBeacon OTA tool

Allows over the air provisioning of all KBeacon Pro (KKM) beacons in the
area. Provides a small UI to set a target advertisement interval, then
scans, authenticates and configures all nearby devices, optionally
POSTing every result to an HTTP endpoint.

Written in Haskell using the [hatter](https://github.com/jappeace/hatter)
mobile framework (like Flutter but Haskell). Compiles to a native
Android APK and an iOS static library.

## Features

- **Filtered scanning**: scans on KKM's `0x2080` service UUID, so only
  KBeacon hardware shows up; deduplicates by address and drops beacons
  below a configurable RSSI threshold (proximity limit, default
  -50 dBm).
- **Configuration over GATT**: full KBeacon config protocol
  (`src/KBeacon/Protocol.hs`, reverse engineered from KKM's
  [android_kbeaconlib2](https://github.com/kkmhogen/android_kbeaconlib2)):
  MD5 challenge-response auth with the factory password, reads the
  current config (battery percent, slot layout), writes the new
  advertisement period to slot 0, disconnects, moves to the next
  beacon.
- **HTTP result reporting**: set the optional report URL and every
  beacon's outcome is POSTed as JSON (name, mac, applied period,
  battery percent with a warning flag under 98%, or the failure
  reason).
- **Battery percent** per beacon, read from the config over GATT.

## Usage

1. Build the APK:
   ```
   nix-build nix/apk.nix
   ```
   (The hatter revision is pinned in `nix/sources/sources.json`;
   update it with `npins update hatter`.)
2. Install `result/kbeacon-ota.apk` on your Android device, or run
   `./install.sh` to build, sideload and tail the app's logcat in one
   go.
3. Accept the BLE permissions (requested at startup; the
   "Request Permissions" button re-asks).
4. Set the advertisement interval (ms, 100 to 40000), adjust the RSSI
   threshold if needed, optionally fill in a report URL.
5. **Start Scan**: nearby KBeacon Pro devices appear.
6. **Configure All**: each listed beacon is configured in turn; the
   list shows per-beacon progress, results and report delivery.

## iOS

The iOS library and Xcode staging build on a Mac:

```
nix-build nix/ios.nix                  # device library
nix-build nix/ios.nix --arg simulator true
nix-build nix/ios-app.nix              # staged Xcode project
```

iOS caveat: CoreBluetooth never exposes MAC addresses, but KBeacon
auth is keyed on the MAC. For factory-named beacons ("KBPro-" plus six
hex digits) the tool reconstructs the MAC from KKM's fixed OUI and the
name suffix, the same data KKM's own iOS library reads from the
advertisement. Beacons that were renamed cannot be configured from iOS
until hatter exposes raw advertisement payloads (see TODO.md).

## Development

```
nix-build nix/ci.nix -A native      # desktop build + unit tests
nix-build nix/ci.nix -A all-builds  # everything the CI build job compiles
```

For iterating with plain cabal, add the hatter and unwitch source
checkouts to an (uncommitted) `cabal.project.local`:

```
packages: /path/to/hatter
          /path/to/unwitch
```

## Testing

Unit tests (`test/Test.hs`) cover the protocol codec: the auth MD5
vectors (generated independently with Python's hashlib), frame
fragmentation and reassembly, ack parsing, the JSON codec and the
config messages.

CI additionally drives the real APK's UI in an Android emulator under
various simulated bluetooth signals (`nix/emulator-ui.nix`,
`test/android/kbeacon.sh`), using the netsim virtual radio and a
bumble-based KBeacon Pro simulator that speaks the same GATT protocol
(`test/android/kbeacon_peripheral.py`):

- a strong-signal KBeacon is discovered and listed;
- a decoy advertising a non-KKM UUID is filtered out;
- raising the RSSI threshold above the beacon's actual signal makes
  the same advertisement get ignored;
- Configure All performs the full auth + read + write handshake
  against the simulated beacon and POSTs the result to a host-side
  report server.

Run it locally (needs KVM):

```
nix-build nix/emulator-ui.nix -o result-emulator-ui
./result-emulator-ui/bin/test-ui
```

## Resources

Original Kotlin implementation reference:
https://github.com/kkmhogen/KBeaconProDemo_Android

KKM's protocol libraries (the wire-format source of truth):
https://github.com/kkmhogen/android_kbeaconlib2 (Java),
https://github.com/kkmhogen/kbeaconlib2 (Swift)
