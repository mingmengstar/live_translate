package com.example.live_translate

import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class OverlayService : Service() {

    companion object {
        const val CHANNEL = "live_translate/overlay"
        const val NOTIFICATION_ID = 1002
        private const val TAG = "OverlayService"
        // Foreground service type for overlay
        const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 4
    }

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var originalTextView: TextView? = null
    private var translatedTextView: TextView? = null
    private var methodChannel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        val flutterEngine = FlutterEngineCache.getInstance().get("live_translate_engine")
            ?: FlutterEngine(this).also { FlutterEngineCache.getInstance().put("live_translate_engine", it) }
        if (!flutterEngine.dartExecutor.isExecutingDart) {
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        }

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "showOverlay" -> {
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        val left = call.argument<Double>("left")?.toInt() ?: 0
                        val top = call.argument<Double>("top")?.toInt() ?: 0
                        showOverlay(fontSize, left, top)
                        result.success(null)
                    }
                    "hideOverlay" -> {
                        hideOverlay()
                        result.success(null)
                    }
                    "updateSubtitle" -> {
                        val original = call.argument<String>("original") ?: ""
                        val translated = call.argument<String>("translated") ?: ""
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        updateSubtitle(original, translated, fontSize)
                        result.success(null)
                    }
                    "updateSettings" -> {
                        val fontSize = call.argument<Double>("fontSize")?.toFloat() ?: 18f
                        updateSettings(fontSize)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()
        val foregroundServiceTypes = FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        startForeground(NOTIFICATION_ID, notification, foregroundServiceTypes)
        return START_STICKY
    }

    private fun showOverlay(fontSize: Float, left: Int, top: Int) {
        if (overlayView != null) return

        windowManager = getSystemService(WindowManager::class.java)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = left
            y = top
        }

        overlayView = LayoutInflater.from(this).inflate(R.layout.overlay_layout, null)
        originalTextView = overlayView?.findViewById(R.id.tv_original)
        translatedTextView = overlayView?.findViewById(R.id.tv_translated)

        originalTextView?.textSize = fontSize
        translatedTextView?.textSize = fontSize

        windowManager?.addView(overlayView!!, params)
    }

    private fun hideOverlay() {
        overlayView?.let { windowManager?.removeView(it) }
        overlayView = null
        originalTextView = null
        translatedTextView = null
    }

    private fun updateSubtitle(original: String, translated: String, fontSize: Float) {
        originalTextView?.text = original
        translatedTextView?.text = translated
        originalTextView?.textSize = fontSize
        translatedTextView?.textSize = fontSize
    }

    private fun updateSettings(fontSize: Float) {
        originalTextView?.textSize = fontSize
        translatedTextView?.textSize = fontSize
    }

    private fun createNotification(): android.app.Notification {
        val channelId = "overlay_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                channelId, "悬浮窗服务", android.app.NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(android.app.NotificationManager::class.java).createNotificationChannel(channel)
        }
        return android.app.Notification.Builder(this, channelId)
            .setContentTitle("实时同传 - 悬浮窗运行中")
            .setContentText("字幕悬浮窗已显示")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        hideOverlay()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}