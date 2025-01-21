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

import androidx.compose.foundation.layout.Column

import androidx.compose.material3.Button
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.KeyboardType
import java.util.concurrent.LinkedBlockingQueue

class Scanner(val queue : LinkedBlockingQueue<KBeacon>)  : KBeaconMgrDelegate {
    val TAG="Scanner"
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

                                if(queue.remainingCapacity() > 1){
                                    queue.put(beacon)
                                    Log.v(TAG, "added");
                                }else{
                                    Log.v(TAG, "ignored queue full");
                                }
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

                }
            }
}
