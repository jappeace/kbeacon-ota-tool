package me.jappie.otatool;

import android.Manifest;
import android.os.Build;
import android.os.Bundle;

import me.jappie.hatter.HatterActivity;

// The launcher activity. All JNI/lifecycle wiring lives in HatterActivity,
// which must stay in package me.jappie.hatter because libhatter.so resolves
// its native methods by the declaring class (Java_me_jappie_hatter_HatterActivity_*).
//
// The full BLE runtime permission set is requested at startup. hatter's
// Haskell permission API (Hatter.Permission) only exposes BLUETOOTH_SCAN,
// but configuring a beacon calls connectGatt, which needs BLUETOOTH_CONNECT
// on API 31+. The in-app "Request Permissions" button covers the Haskell
// side; this covers what that API cannot reach.
public class MainActivity extends HatterActivity {

    private static final int BLE_PERMISSION_REQUEST = 1001;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        String[] permissions;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions = new String[] {
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.ACCESS_FINE_LOCATION
            };
        } else {
            permissions = new String[] {
                Manifest.permission.ACCESS_FINE_LOCATION
            };
        }
        requestPermissions(permissions, BLE_PERMISSION_REQUEST);
    }
}
