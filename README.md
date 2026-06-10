# KBeacon OTA tool

Allows over the air provisioning of all KBeacon Pro beacons in the area.
Provides a small UI to set a target advertisement interval, then scans and
configures all nearby devices.

Written in Haskell using the [hatter](https://github.com/jappeace/hatter)
mobile framework (like Flutter but Haskell). Compiles to a native Android APK.

## Status

BLE **scanning** and UI are implemented. Beacon **configuration** (GATT
connect + write) is pending hatter issue
[#108](https://github.com/jappeace/hatter/issues/108).
See [TODO.md](TODO.md) for the full list of deferred items.

## Usage

1. Pin hatter with npins:
   ```
   npins init
   npins add github jappeace hatter
   ```
2. Build the APK:
   ```
   nix-build nix/apk.nix
   ```
3. Install `result/kbeacon-ota.apk` on your Android device.
4. Press **Request Permissions** and accept BLE permissions.
5. Set your desired advertisement interval (ms).
6. Press **Start Scan** — nearby KBeacon Pro devices appear filtered to
   RSSI ≥ -50 dBm.

## Resources

Original Kotlin implementation reference:
https://github.com/kkmhogen/KBeaconProDemo_Android
