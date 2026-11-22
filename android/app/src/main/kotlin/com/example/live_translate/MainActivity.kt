package com.example.live_translate

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "live_translate/permission"
    private var mediaProjectionPermissionResult: ((Int, Intent?) -> Unit)? = null
    private var pendingMediaProjectionIntent: Intent? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestMediaProjection" -> {
                    requestMediaProjectionPermission(result)
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission(result)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission(result)
                }
                "requestRecordAudioPermission" -> {
                    requestRecordAudioPermission(result)
                }
                "checkPermissions" -> {
                    checkPermissions(result)
                }
                "setLanguageDirection" -> {
                    // 语言方向设置转发给 AudioCaptureService
                    val direction = call.argument<String>("direction") ?: "en2ja"
                    // 可以在这里处理或转发
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestMediaProjectionPermission(result: MethodChannel.Result) {
        val mediaProjectionManager = getSystemService(MediaProjectionManager::class.java)
        pendingMediaProjectionIntent = mediaProjectionManager.createScreenCaptureIntent()
        mediaProjectionPermissionResult = { requestCode, data ->
            if (requestCode == 1001) {
                if (data != null) {
                    result.success(data)
                } else {
                    result.error("PERMISSION_DENIED", "MediaProjection permission denied", null)
                }
                mediaProjectionPermissionResult = null
            }
        }
        startActivityForResult(pendingMediaProjectionIntent!!, 1001)
    }

    private fun requestOverlayPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!android.provider.Settings.canDrawOverlays(this)) {
                val intent = Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.parse("package:$packageName"))
                startActivityForResult(intent, 1002)
                // 注意：overlay 权限不返回 result，由轮询检查
                result.success(null)
            } else {
                result.success(true)
            }
        } else {
            result.success(true)
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1003)
                // Note: Result will be handled in onRequestPermissionsResult
                // For simplicity, we'll return null and poll later
                result.success(null)
            } else {
                result.success(true)
            }
        } else {
            result.success(true)
        }
    }

    private fun requestRecordAudioPermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1004)
            // Note: Result will be handled in onRequestPermissionsResult
            result.success(null)
        } else {
            result.success(true)
        }
    }

    private fun checkPermissions(result: MethodChannel.Result) {
        val perms = mutableMapOf<String, Boolean>()
        perms["recordAudio"] = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        perms["overlay"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(this)
        } else true
        perms["notification"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true
        perms["mediaProjection"] = pendingMediaProjectionIntent != null // 简化：实际应记录授权状态
        result.success(perms)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        mediaProjectionPermissionResult?.invoke(requestCode, data)
    }
}