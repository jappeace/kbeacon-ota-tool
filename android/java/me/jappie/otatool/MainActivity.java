package me.jappie.otatool;

import android.Manifest;
import android.os.Build;
import android.os.Bundle;

import me.jappie.hatter.HatterActivity;

// The launcher activity. All JNI/lifecycle wiring lives in HatterActivity,
// which must stay in package me.jappie.hatter because libhatter.so resolves
// its native methods by the declaring class (Java_me_jappie_hatter_HatterActivity_*).
//
// We request the BLE runtime permissions at startup. hatter's Haskell
// permission API (Hatter.Permission) only exposes BLUETOOTH_SCAN, but the
// scan callback reads BluetoothDevice.getName() -> getRemoteName(), which
// needs BLUETOOTH_CONNECT on API 31+. Without it the first scan result
// crashes with SecurityException, so request the full set here.
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
