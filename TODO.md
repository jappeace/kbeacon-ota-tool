# TODO / known limitations

Everything the original Kotlin tool did is ported: beacon
configuration over GATT, HTTP result reporting, battery percent and
the KKM-only scan (identity from the 0x2080 service data with MAC
prefix and name fallbacks, see `identifyScanResult`) all landed with
the hatter GATT (hatter #108) and advertisement-payload (hatter #238)
APIs, which also brought battery-at-scan and renamed-beacon support
on iOS. What remains:

## 1. Non-default passwords

The tool authenticates with KKM's factory password (sixteen zeros),
like the original Kotlin implementation. Beacons with a changed
password need a password input field wired through to
`KBeacon.Configure` (the protocol layer already takes the password as
a parameter).

## 2. Stall watchdog

Hatter apps run on the non-threaded GHC RTS, so the configure state
machine cannot arm Haskell-side timeouts (see the Decision comment in
`src/KBeacon/Configure.hs`). Failures surface through platform
callbacks and link drops, which covers real beacons; a
connected-but-mute peripheral would stall the session until it
disconnects. Needs a platform timer API in hatter.
