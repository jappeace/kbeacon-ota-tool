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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.example.kbeaconpro.ui.theme.KbeaconproTheme
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyUID
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvType
import com.kkmcn.kbeaconlib2.KBConnPara
import com.kkmcn.kbeaconlib2.KBConnState
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeacon.ConnStateDelegate
import com.kkmcn.kbeaconlib2.KBeaconsMgr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.LinkedBlockingQueue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

class MainActivity : ComponentActivity() {
    val TAG="MainActivity"
    var beaconManager: KBeaconsMgr? = null
    var advPeriod : Float by mutableStateOf(1000.0F)
    var isWriting : Boolean = true
    var sendLogUri : String = "";

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val queue = LinkedBlockingQueue<KBeacon>(50);
        val resultQueue = LinkedBlockingQueue<BeaconResult>(10);
        val doneReport = LinkedBlockingQueue<BeaconResult>(10);
        val me = this;
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
                Row() {
                    Button(
                        onClick = {
                            Log.d(TAG, "requesting permissions")
                            permissions()
                        },
                        modifier = Modifier.padding(top = 16.dp)
                    ) {
                        Text("Request permissions")
                    }
                    Button(
                        onClick = {
                            me.recreate()
                        }
                    ){
                        Text("reset")
                    }
                }
                NumberInputField(onValueChange = {input ->
                    Log.d(TAG, "tax val" + input)
                    advPeriod =  input.toFloat() 

                })
                Text("enable writing")
                SwitchMinimal(onValueChange = { input -> isWriting = input }, onUriChange = { input -> sendLogUri = input })
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
                                var  delegate :  ConnStateDelegate = SetAdvPeriodState(advPeriod, resultQueue)
                                if(!isWriting) {
                                     delegate = ReportAdvPeriodState(advPeriod, sendLogUri, resultQueue)
                                }
                                    val connPara = KBConnPara()
                                    connPara.syncUtcTime = true
                                    connPara.readCommPara = true
                                    connPara.readSlotPara = true
                                    connPara.readTriggerPara = false
                                    connPara.readSensorPara = false
                                    beacon.connectEnhanced(
                                        "0000000000000000",
                                        5000,
                                        connPara,
                                        delegate
                                    );



                            }
                        }
                    },
                    modifier = Modifier.padding(top = 16.dp)
                ) {
                    Text("start scanning")
                }

                ShowMacResults(resultQueue, doneReport, advPeriod)
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
        beaconManager!!.delegate = Scanner(queue, doneReport);

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
fun NumberInputField(
    onValueChange: (String) -> Unit
) {
    var numberText by remember { mutableStateOf("1000") }

    OutlinedTextField(
        value = numberText,
        onValueChange = { input ->
            // Only allow numeric input
            if (input.all { it.isDigit() }) {
                numberText = input  // Update internal state
                onValueChange(input)  // Notify external listener
            }
        },
        label = { Text("adv interval to check or write ") },
        keyboardOptions = KeyboardOptions.Default.copy(
            keyboardType = KeyboardType.Number
        )
    )
}

@Composable
fun ShowMacResults(
    resultQueue:  LinkedBlockingQueue<BeaconResult>,
    doneReport: LinkedBlockingQueue<BeaconResult>,
    expectedAdvPeriod : Float,
){
    val resultState = remember { mutableStateListOf<BeaconResult>() }
    LaunchedEffect(Unit) {
        while (true) {
            
            val result = withContext(Dispatchers.IO) { resultQueue.take() }
            if (result !in resultState) {
                resultState.add(result)
            }
            doneReport.put(result)
        }
    }
    Scaffold { _ ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize(),
            contentPadding = PaddingValues(16.dp)
        ) {
            itemsIndexed(resultState.reversed()) { index, message ->
                var battColor = Color.Black;
                var labelColor = Color.Black;
                if (message.batteryPercent < 95){
                    battColor = Color.Red;
                    labelColor = Color.Red;
                }
                var advColor = Color.Black
                if (message.advPeriod != expectedAdvPeriod){
                    advColor = Color.Red
                    labelColor = Color.Red;
                }
                Row(
                    modifier = Modifier.fillParentMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ){
                    Text(
                    text = (index + 1).toString() + " " + message.name,
                    color = labelColor
                )
                    Text(
                        text = "adv: " + message.advPeriod.toString(),
                        color = advColor
                    )
                    Text(
                        text = "batt: " + message.batteryPercent.toString(),
                        color =  battColor
                    )
                }
            }
        }
    }
}

@Composable
fun SwitchMinimal(    onValueChange: (Boolean) -> Unit, onUriChange: (String) -> Unit) {
    var checked by remember { mutableStateOf(true) }
    var uriText by remember { mutableStateOf("") }

    Switch(
        checked = checked,
        onCheckedChange = {
            checked = it
            onValueChange(it)
        }
    )
    if(! checked){

        OutlinedTextField(
            value = uriText,
            onValueChange = { input ->
                uriText = input  // Update internal state
                onUriChange(input);
            },
            label = { Text("Check results url")},
            keyboardOptions = KeyboardOptions.Default.copy(
                keyboardType = KeyboardType.Uri
            )
        )
    }
}
