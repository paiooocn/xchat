package com.yimo.xchat

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startKeepAlive(call.argument<String>("text"))
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, TurnKeepAliveService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Foreground service so a backgrounded turn is not frozen/killed.
     *
     * Best effort: Android 12+ throws `ForegroundServiceStartNotAllowedException`
     * when the start happens while the app is already in the background — that
     * only costs the keep-alive, the turn itself keeps running in-process.
     */
    private fun startKeepAlive(text: String?) {
        val intent = Intent(this, TurnKeepAliveService::class.java)
            .putExtra(TurnKeepAliveService.EXTRA_TEXT, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            Log.w(TAG, "startForegroundService failed: ${error.message}")
        }
    }

    companion object {
        private const val CHANNEL = "xchat/keep_alive"
        private const val TAG = "XChatKeepAlive"
    }
}
