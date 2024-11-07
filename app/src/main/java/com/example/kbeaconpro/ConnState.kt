package com.example.kbeaconpro

import android.util.Log
import androidx.core.content.PackageManagerCompat.LOG_TAG
import com.kkmcn.kbeaconlib2.KBConnState
import com.kkmcn.kbeaconlib2.KBConnectionEvent
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeacon.ConnStateDelegate


class ConnState : ConnStateDelegate {
    val TAG = "ConnState"
    override fun onConnStateChange(beacon: KBeacon?, state: KBConnState?, nReason: Int) {
        if (state == KBConnState.Connected) {
            Log.i(TAG, "device has connected")
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

