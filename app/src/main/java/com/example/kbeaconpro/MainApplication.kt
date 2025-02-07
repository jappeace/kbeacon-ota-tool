package com.example.kbeaconpro

import android.app.Application
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import kotlin.system.exitProcess

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()

        // Set up the global exception handler
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // Log the exception (for debugging purposes)
            Log.e("UncaughtException", "Exception in thread ${thread.name}", throwable)

            // Option 1: Launch a dedicated error reporting activity (recommended)
            val intent = Intent(applicationContext, ErrorActivity::class.java).apply {
                putExtra("error", Log.getStackTraceString(throwable))
                // Clear the activity stack and start a new task
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }

            // Option 2: Alternatively, you could launch MainActivity if preferred
            // val intent = Intent(applicationContext, MainActivity::class.java).apply {
            //     putExtra("error", Log.getStackTraceString(throwable))
            //     addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            // }

            // Start the error reporting activity
            startActivity(intent)

            // Delay process termination to give the new activity time to launch
            Handler(Looper.getMainLooper()).postDelayed({
                Process.killProcess(Process.myPid())
                exitProcess(1)
            }, 3000)  // 3-second delay (adjust as needed)
        }

    }
}
