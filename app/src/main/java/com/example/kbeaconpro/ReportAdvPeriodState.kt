package com.example.kbeaconpro

import android.util.Log
import com.kkmcn.kbeaconlib2.KBConnState
import com.kkmcn.kbeaconlib2.KBConnectionEvent
import com.kkmcn.kbeaconlib2.KBeacon
import com.kkmcn.kbeaconlib2.KBeacon.ConnStateDelegate
import java.net.HttpURLConnection
import java.net.URL


class ReportAdvPeriodState(val expected: Float, val to : String) : ConnStateDelegate {
    val TAG = "ConnState"
    override fun onConnStateChange(beacon: KBeacon?, state: KBConnState?, nReason: Int) {
        if (state == KBConnState.Connected) {
            Log.i(TAG, "device has connected")
            val oldCfgPara = beacon!!.getSlotCfg(0)
            if(oldCfgPara == null){
                beacon!!.disconnect()
                return
            }
            val period = oldCfgPara.advPeriod
                val thread = Thread( {
                var logMsg = "incorrect adv period " + beacon.mac + " is "+ period.toString() + " expected " + expected
                if(period == expected){
                  logMsg = "adv period " + beacon.mac + " is "+ period.toString() + " as expected"
                }
                Log.i(TAG, logMsg)
                // 1. Parse the String into a URL:
                val url = URL(to)

                // 2. Open a connection to the URL, cast it to HttpURLConnection
                val connection = url.openConnection() as HttpURLConnection
                Log.i(TAG, "connecting to $url")
                try {
                    // Configure the connection:
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.connectTimeout = 5000  // Optional: set connection timeout (ms)
                    connection.readTimeout = 5000     // Optional: set read timeout (ms)
                    connection.setRequestProperty("Content-Type", "text/plain;charset=utf-8")
                    connection.setRequestProperty("Accept", "application/json")
                    // 3. Write some text to the request body:
                    val body = logMsg
                    connection.outputStream.use { outputStream ->
                        outputStream.write(body.toByteArray(Charsets.UTF_8))
                    }

                    // Check the response code
                    val responseCode = connection.responseCode
                    Log.i(TAG, "Response Code: $responseCode")

                    // 4. Read the response:
                    val response = connection.inputStream.bufferedReader().use { it.readText() }
                    Log.i(TAG, "Response Body: $response")

                } catch (e: Exception) {
                    Log.e(TAG, "got some exception")
                    Log.e(TAG, Log.getStackTraceString(e))
                    e.message?.let { Log.e(TAG, it) }
                } finally {
                    connection.disconnect()
                }
                    
                })
                thread.start()
            beacon!!.disconnect()
        } else if (state == KBConnState.Connecting) {
            Log.i(TAG, "device start connecting")
        } else if (state == KBConnState.Disconnecting) {
            Log.i(TAG, "device start disconnecting")
        } else if (state == KBConnState.Disconnected) {
            if (nReason == KBConnectionEvent.ConnAuthFail) {
                Log.e(TAG, "password error")
            } else if (nReason == KBConnectionEvent.ConnTimeout) {
                Log.i(TAG, "connection timeout")
            } else {
                Log.i(TAG, "connection other error, reason:$nReason")
            }

            Log.v(TAG, "device has disconnected:$nReason")
        }
    }
}

