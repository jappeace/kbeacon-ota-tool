package com.example.kbeaconpro

import android.util.Log
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEBeacon
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyTLM
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyUID
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketEddyURL
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvPacketSystem
import com.kkmcn.kbeaconlib2.KBAdvPackage.KBAdvType
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeaconsMgr.KBeaconMgrDelegate
import java.util.concurrent.LinkedBlockingQueue


class Scanner(val queue : LinkedBlockingQueue<KBeacon>)  : KBeaconMgrDelegate {
    val rssiProximalLimit: Int = -50
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
                                    var isInQueue = false
                                    for(next in queue){
                                        if(next.mac == beacon.mac){
                                            isInQueue = true
                                            break
                                        }
                                    }
                                    if(beacon.rssi < rssiProximalLimit){
                                        Log.i(TAG, "ignored " + beacon.mac + " because rssi is " + beacon.rssi.toString());

                                        continue
                                    }
                                    if(!isInQueue){
                                        Log.i(TAG, "added " + beacon.mac);
                                        queue.put(beacon)
                                    }else{
                                        Log.i(TAG, "already in queue " + beacon.mac);
                                    }
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
