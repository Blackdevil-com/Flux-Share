package com.example.fluxshare

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.example.fluxshare/background_service"
        const val MULTICAST_CHANNEL = "com.fluxshare/multicast_lock"
    }

    private var methodChannel: MethodChannel? = null
    private var cancelReceiver: BroadcastReceiver? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService" -> {
                        val title = call.argument<String>("title") ?: "FluxShare Transfer"
                        val message = call.argument<String>("message") ?: "Transferring..."
                        val progress = call.argument<Int>("progress") ?: 0
                        val maxProgress = call.argument<Int>("maxProgress") ?: 100

                        val intent = Intent(context, TransferForegroundService::class.java).apply {
                            action = TransferForegroundService.ACTION_START
                            putExtra(TransferForegroundService.EXTRA_TITLE, title)
                            putExtra(TransferForegroundService.EXTRA_MESSAGE, message)
                            putExtra(TransferForegroundService.EXTRA_PROGRESS, progress)
                            putExtra(TransferForegroundService.EXTRA_MAX_PROGRESS, maxProgress)
                        }

                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                context.startForegroundService(intent)
                            } else {
                                context.startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE_START_FAILED", e.message, null)
                        }
                    }

                    "updateNotification" -> {
                        val title = call.argument<String>("title") ?: "FluxShare Transfer"
                        val message = call.argument<String>("message") ?: "Transferring..."
                        val progress = call.argument<Int>("progress") ?: 0
                        val maxProgress = call.argument<Int>("maxProgress") ?: 100

                        val intent = Intent(context, TransferForegroundService::class.java).apply {
                            action = TransferForegroundService.ACTION_UPDATE
                            putExtra(TransferForegroundService.EXTRA_TITLE, title)
                            putExtra(TransferForegroundService.EXTRA_MESSAGE, message)
                            putExtra(TransferForegroundService.EXTRA_PROGRESS, progress)
                            putExtra(TransferForegroundService.EXTRA_MAX_PROGRESS, maxProgress)
                        }

                        try {
                            context.startService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("UPDATE_FAILED", e.message, null)
                        }
                    }

                    "stopForegroundService" -> {
                        val intent = Intent(context, TransferForegroundService::class.java).apply {
                            action = TransferForegroundService.ACTION_STOP
                        }
                        try {
                            context.startService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }

                    "isForegroundRunning" -> {
                        result.success(TransferForegroundService.isServiceRunning)
                    }

                    "getAvailableStorageBytes" -> {
                        val path = call.argument<String>("path") ?: context.filesDir.absolutePath
                        try {
                            val stat = android.os.StatFs(path)
                            val bytesAvailable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                                stat.availableBytes
                            } else {
                                @Suppress("DEPRECATION")
                                (stat.availableBlocks.toLong() * stat.blockSize.toLong())
                            }
                            result.success(bytesAvailable)
                        } catch (e: Exception) {
                            result.error("STATFS_FAILED", e.message, null)
                        }
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }

        // MulticastLock and WifiLock Channel for reliable UDP discovery & Hotspot transfers
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MULTICAST_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                            if (multicastLock == null) {
                                multicastLock = wifiManager?.createMulticastLock("FluxShareMulticastLock")?.apply {
                                    setReferenceCounted(true)
                                }
                            }
                            if (multicastLock?.isHeld != true) {
                                multicastLock?.acquire()
                            }
                            if (wifiLock == null) {
                                wifiLock = wifiManager?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "FluxShareWifiLock")?.apply {
                                    setReferenceCounted(true)
                                }
                            }
                            if (wifiLock?.isHeld != true) {
                                wifiLock?.acquire()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LOCK_ACQUIRE_FAILED", e.message, null)
                        }
                    }

                    "releaseMulticastLock" -> {
                        try {
                            if (multicastLock?.isHeld == true) {
                                multicastLock?.release()
                            }
                            if (wifiLock?.isHeld == true) {
                                wifiLock?.release()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LOCK_RELEASE_FAILED", e.message, null)
                        }
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }

        // Register receiver for cancel action from ongoing notification
        cancelReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == TransferForegroundService.ACTION_CANCEL_TRANSFER) {
                    methodChannel?.invokeMethod("onNotificationCancel", null)
                }
            }
        }

        val filter = IntentFilter(TransferForegroundService.ACTION_CANCEL_TRANSFER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(cancelReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(cancelReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
            multicastLock = null
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            e.printStackTrace()
        }

        cancelReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                e.printStackTrace()
            }
            cancelReceiver = null
        }
        methodChannel = null
        super.onDestroy()
    }
}
