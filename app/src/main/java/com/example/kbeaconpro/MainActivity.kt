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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.example.kbeaconpro.ui.theme.KbeaconproTheme
import com.kkmcn.kbeaconlib2.KBConnPara
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeaconsMgr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.LinkedBlockingQueue


class MainActivity : ComponentActivity() {
    val TAG="MainActivity"
    var beaconManager: KBeaconsMgr? = null
    var advPeriod : Float = 1000.0F

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val queue = LinkedBlockingQueue<KBeacon>(50);
        setContent {
            KbeaconproTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            Column(
                modifier = Modifier
                    .padding(innerPadding)
                    .fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Greeting(name = "Android")

                Button(
                    onClick = {
                        Log.d(TAG, "requestion permissions")
                        permissions()
                    },
                    modifier = Modifier.padding(top = 16.dp)
                ) {
                    Text("Requst permissions")
                }
                NumberInputField(onValueChange = {input ->
                    Log.d(TAG, "tax val" + input)
                    advPeriod =  input.toFloat()
                })
                Button(
                    onClick = {
        val nStartScan: Int = beaconManager!!.startScanning()
        if (nStartScan == 0) {
            Log.v(TAG, "start scan success")
        } else if (nStartScan == KBeaconsMgr.SCAN_ERROR_BLE_NOT_ENABLE) {
            toastShow("BLE function is not enable")
        } else if (nStartScan == KBeaconsMgr.SCAN_ERROR_UNKNOWN) {
            toastShow("Please make sure the app has BLE scan permission")
        }
                        lifecycleScope.launch(Dispatchers.IO) {
                            Log.v(TAG, "Running background task on IO dispatcher: ${Thread.currentThread().name}");
                            while(beaconManager!!.isScanning() || (! queue.isEmpty())){
                                val beacon = queue.poll();
                                if(beacon == null){
                                    delay(1)
                                    continue;
                                }
                                Log.v(TAG, "connecting to mac:" + beacon.mac)
                                val connPara = KBConnPara()
                                connPara.syncUtcTime = true
                                connPara.readCommPara = true
                                connPara.readSlotPara = true
                                connPara.readTriggerPara = false
                                connPara.readSensorPara = false
                                beacon.connectEnhanced("0000000000000000", 5000, connPara, ConnState(advPeriod));
                                
                            }
                        }
                    },
                    modifier = Modifier.padding(top = 16.dp)
                ) {
                    Text("start scanning")
                }

            }
                }
            }
        }
        this.beaconManager = KBeaconsMgr.sharedBeaconManager(this);
        if (beaconManager == null)
        {
            toastShow( "Make sure the phone supports BLE function");
            return;
        }
        beaconManager!!.delegate = Scanner(queue);

    }
fun toastShow(message: String){
    Toast.makeText(this, message, Toast.LENGTH_LONG).show();
}
fun permissions(){

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

@Composable
fun NumberInputField(
    onValueChange: (String) -> Unit
) {
    var numberText by remember { mutableStateOf("") }

    OutlinedTextField(
        value = numberText,
        onValueChange = { input ->
            // Only allow numeric input
            if (input.all { it.isDigit() }) {
                numberText = input  // Update internal state
                onValueChange(input)  // Notify external listener
            }
        },
        label = { Text("Enter number") },
        keyboardOptions = KeyboardOptions.Default.copy(
            keyboardType = KeyboardType.Number
        )
    )
}
