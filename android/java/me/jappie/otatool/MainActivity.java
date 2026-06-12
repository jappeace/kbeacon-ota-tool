package me.jappie.otatool;

import me.jappie.hatter.HatterActivity;

// The launcher activity. All JNI/lifecycle wiring lives in HatterActivity,
// which must stay in package me.jappie.hatter because libhatter.so resolves
// its native methods by the declaring class (Java_me_jappie_hatter_HatterActivity_*).
//
// BLE permissions (BLUETOOTH_SCAN + ACCESS_FINE_LOCATION) are requested from
// Haskell via the "Request Permissions" button (Hatter.Permission). No
// BLUETOOTH_CONNECT is needed: hatter reads the advertised name from the scan
// record rather than getRemoteName().
public class MainActivity extends HatterActivity {}
