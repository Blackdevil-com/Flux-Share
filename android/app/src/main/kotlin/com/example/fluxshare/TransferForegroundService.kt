package com.example.fluxshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class TransferForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "fluxshare_transfers"
        const val CHANNEL_NAME = "FluxShare File Transfers"
        const val NOTIFICATION_ID = 9182

        const val ACTION_START = "com.example.fluxshare.ACTION_START"
        const val ACTION_UPDATE = "com.example.fluxshare.ACTION_UPDATE"
        const val ACTION_STOP = "com.example.fluxshare.ACTION_STOP"
        const val ACTION_CANCEL_TRANSFER = "com.example.fluxshare.ACTION_CANCEL_TRANSFER"

        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_MESSAGE = "extra_message"
        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_MAX_PROGRESS = "extra_max_progress"
        const val EXTRA_SPEED = "extra_speed"
        const val EXTRA_ETA = "extra_eta"

        @Volatile
        var isServiceRunning = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var notificationManager: NotificationManager? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
        acquireLocks()
        isServiceRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            return START_NOT_STICKY
        }

        when (intent.action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "FluxShare Transfer"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Transferring files in background..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val max = intent.getIntExtra(EXTRA_MAX_PROGRESS, 100)

                val notification = buildNotification(title, message, progress, max)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }

            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "FluxShare Transfer"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Transferring..."
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val max = intent.getIntExtra(EXTRA_MAX_PROGRESS, 100)

                val notification = buildNotification(title, message, progress, max)
                notificationManager?.notify(NOTIFICATION_ID, notification)
            }

            ACTION_STOP -> {
                stopTransferService()
            }
        }

        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "FluxShare:TransferWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "FluxShare:WifiLock")
                } else {
                    @Suppress("DEPRECATION")
                    wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "FluxShare:WifiLock")
                }.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            e.printStackTrace()
        }

        try {
            wifiLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wifiLock = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps FluxShare transfer active when screen is off or in background"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            notificationManager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(
        title: String,
        message: String,
        progress: Int,
        maxProgress: Int
    ): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = Intent(ACTION_CANCEL_TRANSFER).apply {
            setPackage(packageName)
        }
        val cancelPendingIntent = PendingIntent.getBroadcast(
            this,
            1,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(openAppPendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                cancelPendingIntent
            )

        if (maxProgress > 0) {
            builder.setProgress(maxProgress, progress.coerceIn(0, maxProgress), false)
        } else {
            builder.setProgress(0, 0, true)
        }

        return builder.build()
    }

    private fun stopTransferService() {
        releaseLocks()
        isServiceRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        releaseLocks()
        isServiceRunning = false
        super.onDestroy()
    }
}
