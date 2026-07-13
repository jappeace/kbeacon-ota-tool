# TODO / known limitations

Everything the original Kotlin tool did is ported: beacon
configuration over GATT, HTTP result reporting, battery percent and
the KKM-only scan (a software identity gate on KKM's MAC prefix, see
`identifyScanResult`) all landed with the hatter GATT API (hatter
#108). What remains:

## 1. Renamed beacons on iOS

KBeacon auth is keyed on the device MAC, which iOS never exposes.
Factory-named beacons work (the MAC is reconstructed from KKM's OUI
plus the "KBPro-XXXXXX" name suffix); renamed ones need the MAC from
the advertisement's system packet or 0x2080 service data, which
hatter's `BleScanResult` does not carry. Needs a hatter scan-result
extension exposing raw advertisement payloads (follow-up to
https://github.com/jappeace/hatter/issues/108).

## 2. Advertisement-level battery percent

Battery is currently read over GATT (`"btPt"` in the config JSON),
which requires connecting. KBeacons also broadcast it in byte 0 of the
0x2080 service data, which would show battery for beacons that are
merely scanned; blocked on the same raw-advertisement hatter extension
as item 1.

## 3. Non-default passwords

The tool authenticates with KKM's factory password (sixteen zeros),
like the original Kotlin implementation. Beacons with a changed
password need a password input field wired through to
`KBeacon.Configure` (the protocol layer already takes the password as
a parameter).

## 4. Stall watchdog

Hatter apps run on the non-threaded GHC RTS, so the configure state
machine cannot arm Haskell-side timeouts (see the Decision comment in
`src/KBeacon/Configure.hs`). Failures surface through platform
callbacks and link drops, which covers real beacons; a
connected-but-mute peripheral would stall the session until it
disconnects. Needs a platform timer API in hatter.
