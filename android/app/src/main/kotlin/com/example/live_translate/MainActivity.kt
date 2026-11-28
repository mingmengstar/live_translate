package com.example.live_translate

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    
    private val CHANNEL = "live_translate/permissions"
    private val AUDIO_CAPTURE_CHANNEL = "live_translate/audio_capture"
    private val AUDIO_STREAM_CHANNEL = "live_translate/audio_stream"
    private val OVERLAY_PERMISSION_REQUEST_CODE = 1001
    private val AUDIO_PERMISSION_REQUEST_CODE = 1002
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 1003
    private val MEDIA_PROJECTION_REQUEST_CODE = 1004
    
    private var pendingOverlayPermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingAudioPermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingNotificationPermissionCallback: ((Boolean) -> Unit)? = null
    private var pendingProjectionCallback: ((Boolean) -> Unit)? = null
    
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        // 系统内录控制通道（替代损坏的 system_audio_recorder 插件）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CAPTURE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestProjection" -> {
                    requestMediaProjection { granted -> result.success(granted) }
                }
                "startCapture" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 16000
                    result.success(AudioCaptureService.startCapture(applicationContext, sampleRate))
                }
                "stopCapture" -> {
                    AudioCaptureService.stopCapture(applicationContext)
                    result.success(true)
                }
                "isCapturing" -> {
                    result.success(AudioCaptureService.isCapturing)
                }
                else -> result.notImplemented()
            }
        }

        // PCM 数据流（20ms 一块，PCM16 单声道）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_STREAM_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    AudioCaptureService.attachSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    AudioCaptureService.attachSink(null)
                }
            }
        )
        
        // 设置权限检查 MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkOverlayPermission" -> {
                    result.success(checkOverlayPermission())
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission { granted ->
                        result.success(granted)
                    }
                }
                "checkAudioPermission" -> {
                    result.success(checkAudioPermission())
                }
                "requestAudioPermission" -> {
                    requestAudioPermission { granted ->
                        result.success(granted)
                    }
                }
                "checkNotificationPermission" -> {
                    result.success(checkNotificationPermission())
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission { granted ->
                        result.success(granted)
                    }
                }
                "showOverlayPermissionNotification" -> {
                    showOverlayPermissionNotification()
                    result.success(true)
                }
                "openOverlaySettings" -> {
                    openOverlaySettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 预检查权限
        checkAndRequestPermissions()
    }

    /// 回到前台时复查悬浮窗权限（BUG-2 双保险）
    ///
    /// 用户在系统设置页授权后返回 App，部分 ROM 不会回调
    /// `onActivityResult`，但 `onResume` 一定会走到。
    override fun onResume() {
        super.onResume()
        resolvePendingOverlayPermission()
    }
    
    /// 检查并请求必要权限
    private fun checkAndRequestPermissions() {
        // 检查音频录制权限
        if (!checkAudioPermission()) {
            requestAudioPermission { _ -> }
        }
        
        // 检查通知权限 (Android 13+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (!checkNotificationPermission()) {
                requestNotificationPermission { _ -> }
            }
        }
    }
    
    /// 检查悬浮窗权限
    private fun checkOverlayPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return Settings.canDrawOverlays(this)
        }
        return true // Android 6.0 以下默认有权限
    }
    
    /// 请求悬浮窗权限
    ///
    /// ## 为什么不能只靠 startActivityForResult 的返回值（BUG-2 根因之一）
    ///
    /// 旧实现把结果完全押在 `onActivityResult` 上：
    ///
    /// - 用户被跳转到「显示在其他应用上层」系统设置页；
    /// - 授权后按返回键回到 App；
    /// - 部分 ROM（尤其 MIUI / HyperOS / EMUI）**不会**稳定回调
    ///   `onActivityResult`，或回调时 `Settings.canDrawOverlays()` 还
    ///   没同步完成 → 回调里读到 `false`；
    /// - 于是 Dart 侧收到 `PERMISSION`，悬浮窗永远起不来，而用户
    ///   明明已经在设置里打开了开关。
    ///
    /// 现在改成「跳设置页 + 回前台时复查」双保险，并且**授权结果以
    /// `Settings.canDrawOverlays()` 为准**，而不是以 resultCode 为准。
    private fun requestOverlayPermission(callback: (Boolean) -> Unit) {
        if (checkOverlayPermission()) {
            callback(true)
            return
        }

        pendingOverlayPermissionCallback = callback

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                // NEW_TASK：某些 ROM 上该设置页需要独立任务栈，
                // 否则 startActivityForResult 会立刻返回 RESULT_CANCELED。
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "打开悬浮窗权限页失败: ${e.message}", e)
                pendingOverlayPermissionCallback = null
                callback(false)
            }
        } else {
            callback(true)
        }
    }

    /// 回前台时补一次权限复查（BUG-2 双保险）
    ///
    /// 只处理「有一个悬浮窗权限请求在等结果」的情况，避免误触发
    /// 其它渠道的回调。授权与否一律以系统真实权限为准。
    private fun resolvePendingOverlayPermission() {
        val cb = pendingOverlayPermissionCallback ?: return
        if (checkOverlayPermission()) {
            pendingOverlayPermissionCallback = null
            cb(true)
        }
        // 仍未授权就继续等：用户可能只是切出去看了一眼又回来了，
        // 不能在这里武断地回 false（那正是旧实现的表现）。
    }
    
    /// 检查音频权限
    private fun checkAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }
    
    /// 请求音频权限
    private fun requestAudioPermission(callback: (Boolean) -> Unit) {
        if (checkAudioPermission()) {
            callback(true)
            return
        }
        
        // 保存回调以便在 onRequestPermissionsResult 中使用
        pendingAudioPermissionCallback = callback
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), AUDIO_PERMISSION_REQUEST_CODE)
    }
    
    /// 检查通知权限
    private fun checkNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }
        return true
    }
    
    /// 请求通知权限
    private fun requestNotificationPermission(callback: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkNotificationPermission()) {
                callback(true)
                return
            }
            // 保存回调以便在 onRequestPermissionsResult 中使用
            pendingNotificationPermissionCallback = callback
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST_CODE)
        } else {
            callback(true)
        }
    }
    
    /// 显示悬浮窗权限引导通知（高优先级）
    private fun showOverlayPermissionNotification() {
        // 这里应该创建一个高优先级通知，引导用户开启悬浮窗权限
        // 实际实现需要 NotificationManager 和 NotificationChannel
        // 简化版：直接跳转设置页
        openOverlaySettings()
    }
    
    /// 请求屏幕录制（系统内录）授权
    ///
    /// 注意：Android 14+ 的 MediaProjection 授权 token **只能用一次**，
    /// 因此这里不做缓存复用，每次开始录制都重新弹一次系统授权框。
    /// 否则复用过期的 data 会让 getMediaProjection() 抛 SecurityException。
    private fun requestMediaProjection(callback: (Boolean) -> Unit) {
        pendingProjectionCallback = callback
        // 清掉旧凭证，防止误用已消费的 token
        AudioCaptureService.grantedResultCode = Activity.RESULT_CANCELED
        AudioCaptureService.grantedResultData = null
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(manager.createScreenCaptureIntent(), MEDIA_PROJECTION_REQUEST_CODE)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "请求屏幕录制失败: ${e.message}", e)
            pendingProjectionCallback = null
            callback(false)
        }
    }

    /// 打开悬浮窗权限设置页
    private fun openOverlaySettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
            startActivity(intent)
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == OVERLAY_PERMISSION_REQUEST_CODE) {
            // 以系统真实权限为准，而不是 resultCode：
            // 部分 ROM 在「用户在设置页打开开关」后仍回 RESULT_CANCELED。
            val granted = checkOverlayPermission()
            val cb = pendingOverlayPermissionCallback
            pendingOverlayPermissionCallback = null
            cb?.invoke(granted)
        } else if (requestCode == MEDIA_PROJECTION_REQUEST_CODE) {
            val granted = resultCode == Activity.RESULT_OK && data != null
            if (granted) {
                // 保存凭证，供前台服务使用
                AudioCaptureService.grantedResultCode = resultCode
                AudioCaptureService.grantedResultData = data
            }
            pendingProjectionCallback?.invoke(granted)
            pendingProjectionCallback = null
        }
    }
    
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        
        when (requestCode) {
            AUDIO_PERMISSION_REQUEST_CODE -> {
                val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingAudioPermissionCallback?.invoke(granted)
                pendingAudioPermissionCallback = null
            }
            NOTIFICATION_PERMISSION_REQUEST_CODE -> {
                val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
                pendingNotificationPermissionCallback?.invoke(granted)
                pendingNotificationPermissionCallback = null
            }
        }
    }
}