package com.yimo.xchat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process out of the "cached" bucket while a turn is streaming.
 *
 * Android freezes or kills a backgrounded process (cached-app freezer, Doze,
 * OEM cleaners); the SSE socket then dies and the answer stops half-way. A
 * low-priority foreground notification is the only supported way to keep the
 * work alive. Started by [MainActivity] only while a turn is running.
 */
class TurnKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() }
            ?: "正在生成回答…"
        startWithNotification(text)
        return START_NOT_STICKY
    }

    private fun startWithNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "生成中",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "回答生成期间保持后台运行"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(appLabel())
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun appLabel(): String =
        applicationInfo.loadLabel(packageManager)?.toString() ?: "XChat"

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "xchat_generating"
        const val NOTIFICATION_ID = 0x5843 // "XC"
        const val EXTRA_TEXT = "text"
    }
}
