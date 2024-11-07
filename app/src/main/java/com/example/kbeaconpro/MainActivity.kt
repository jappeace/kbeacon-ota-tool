package com.example.kbeaconpro

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.kbeaconpro.ui.theme.KbeaconproTheme
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEBeacon
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyTLM
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyUID
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyURL
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketIBeacon
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketSensor
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketSystem
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvType
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeaconsMgr
import com.kkmcn.kbeaconlib2.KBeaconsMgr.KBeaconMgrDelegate


class MainActivity : ComponentActivity() {
    val TAG="MainActivity"
    var beaconManager: KBeaconsMgr? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            KbeaconproTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                    Greeting(
                        name = "Android",
                        modifier = Modifier.padding(innerPadding)
                    )
                }
            }
        }
        this.beaconManager = KBeaconsMgr.sharedBeaconManager(this);
        if (beaconManager == null)
        {
            toastShow( "Make sure the phone supports BLE function");
            return;
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION)
            != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION), 0);
        }
//for android10, the app need fine location permission for BLE scanning
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 1);
        }
//for android 12, the app need declare follow permissions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.BLUETOOTH_SCAN), 2);
            }

            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 3);
            }
        }
        beaconManager!!.delegate =  object : KBeaconMgrDelegate {
            override fun onCentralBleStateChang(nNewState: Int) {}
            override fun onScanFailed(errorCode: Int) {}
            //get advertisement packet during scanning callback
            override fun onBeaconDiscovered(beacons: Array<KBeacon>) {
                Log.v(TAG, "found beacon")
                for (beacon in beacons) {
                    //get beacon adv common info
                    Log.v(TAG, "beacon mac:" + beacon.mac)
                    Log.v(TAG, "beacon name:" + beacon.name)
                    Log.v(TAG, "beacon rssi:" + beacon.rssi)

                    //get adv packet
                    for (advPacket in beacon.allAdvPackets()) {
                        when (advPacket.advType) {
                            KBAdvType.IBeacon -> {
                                Log.v(TAG, "ibeacon, unlikely branch");
                            }

                            KBAdvType.EddyTLM -> {
                                val advTLM = advPacket as KBAdvPacketEddyTLM
                                Log.v(TAG, "TLM battery:" + advTLM.batteryLevel)
                                Log.v(TAG, "TLM Temperature:" + advTLM.temperature)
                                Log.v(TAG, "TLM adv count:" + advTLM.advCount)
                            }

                                KBAdvType.Sensor -> {
                                Log.v(TAG, "sensor, unlikely branch");
                                }

                            KBAdvType.EddyUID -> {
                                val advUID = advPacket as KBAdvPacketEddyUID
                                Log.v(TAG, "UID Nid:" + advUID.nid)
                                Log.v(TAG, "UID Sid:" + advUID.sid)
                            }

                            KBAdvType.EddyURL -> {
                                val advURL = advPacket as KBAdvPacketEddyURL
                                Log.v(TAG, "URL:" + advURL.url)
                            }

                            KBAdvType.System -> {
                                val advSystem = advPacket as KBAdvPacketSystem
                                Log.v(TAG, "System mac:" + advSystem.macAddress)
                                Log.v(TAG, "System model:" + advSystem.model)
                                Log.v(TAG, "System batt:" + advSystem.batteryPercent)
                                Log.v(TAG, "System ver:" + advSystem.version)
                            }

                            KBAdvType.EBeacon -> {
                                val encryptAdv = advPacket as KBAdvPacketEBeacon
                                Log.v(TAG, "System mac:" + encryptAdv.mac)
                                Log.v(TAG, "Decrypt UUID:" + encryptAdv.uuid)
                                Log.v(TAG, "ADV UTC:" + encryptAdv.utcSecCount)
                                Log.v(TAG, "Reference power:" + encryptAdv.refTxPower)
                            }

                            else -> {}
                        }
                    }

                    //clear all scanned packet
                    beacon.removeAdvPacket()
                }
            }
        };
        val nStartScan: Int = beaconManager!!.startScanning()
        if (nStartScan == 0) {
            Log.v(TAG, "start scan success")
        } else if (nStartScan == KBeaconsMgr.SCAN_ERROR_BLE_NOT_ENABLE) {
            toastShow("BLE function is not enable")
        } else if (nStartScan == KBeaconsMgr.SCAN_ERROR_UNKNOWN) {
            toastShow("Please make sure the app has BLE scan permission")
        }
    }
fun toastShow(message: String){
    Toast.makeText(this, message, Toast.LENGTH_LONG);
}
}

@Composable
fun Greeting(name: String, modifier: Modifier = Modifier) {
    Text(
        text = "Hello $name!",
        modifier = modifier
    )
}


@Preview(showBackground = true)
@Composable
fun GreetingPreview() {
    KbeaconproTheme {
        Greeting("Android")
    }
}
