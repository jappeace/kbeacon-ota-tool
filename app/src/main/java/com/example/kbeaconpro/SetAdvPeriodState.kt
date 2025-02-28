package com.example.kbeaconpro

import android.util.Log
import com.kkmcn.kbeaconlib2.KBConnState
import com.kkmcn.kbeaconlib2.KBConnectionEvent
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeacon.ConnStateDelegate
import java.util.concurrent.LinkedBlockingQueue


class SetAdvPeriodState(val advertisePeriod : Float, val resultQueue: LinkedBlockingQueue<BeaconResult>) : ConnStateDelegate {
    val TAG = "ConnState"
    override fun onConnStateChange(beacon: KBeacon?, state: KBConnState?, nReason: Int) {
        if (state == KBConnState.Connected) {
            Log.i(TAG, "device has connected")
            val oldCfgPara = beacon!!.getSlotCfg(0)
            oldCfgPara.setAdvPeriod(advertisePeriod)
            val mac = beacon.mac
            val name = beacon.name
            beacon.modifyConfig(oldCfgPara) { bConfigSuccess, error ->
                // TODO this doesn't appear to be ever executed??
                var logMsg = "adv period " + name + " " + mac + " set to "+ advertisePeriod.toString()
                if (bConfigSuccess) {
                    Log.i(TAG,logMsg)
                } else {
                    logMsg = "failed setting " + name + " " + mac + " because " + error.errorCode
                    Log.i(TAG,logMsg)
                }
            }
            resultQueue.put(BeaconResult(name, mac, advertisePeriod, beacon.batteryPercent))
            beacon!!.disconnect()
        } else if (state == KBConnState.Connecting) {
            Log.i(TAG, "device start connecting")
        } else if (state == KBConnState.Disconnecting) {
            Log.i(TAG, "device start disconnecting")
        } else if (state == KBConnState.Disconnected) {
            if (nReason == KBConnectionEvent.ConnAuthFail) {
                Log.e(TAG, "password error")
            } else if (nReason == KBConnectionEvent.ConnTimeout) {
                Log.e(TAG, "connection timeout")
            } else {
                Log.e(TAG, "connection other error, reason:$nReason")
            }

            Log.e(TAG, "device has disconnected:$nReason")
        }
    }
}

