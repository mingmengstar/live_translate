package com.example.live_translate

import android.app.Service
import android.content.Intent
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/// 悬浮窗专用的 Flutter Engine 服务
/// 作为独立的 Flutter 引擎运行，通过 FlutterScreenOverlay 显示
class OverlayFlutterEngine : Service() {
    
    private var flutterEngine: FlutterEngine? = null
    private val CHANNEL = "live_translate/overlay"
    
    override fun onCreate() {
        super.onCreate()
        initFlutterEngine()
    }
    
    private fun initFlutterEngine() {
        // 创建或获取缓存的 Flutter Engine
        flutterEngine = FlutterEngineCache.getInstance().get("overlay_engine") ?: FlutterEngine(this).apply {
            // 启动引擎，指定 Dart 入口点为 overlayMain（lib/ui/overlay_screen.dart）
            //
            // 关键点：
            // 1. FlutterEngine 没有 runAppWithEntrypoint 方法，必须走 executeDartEntrypoint。
            // 2. 用 FlutterInjector 拿到正确的 assets bundle 路径，不能写死 "/"，否则运行时
            //    资源加载失败。
            // 3. 本 Service 跑在独立进程 (:overlay) 中，FlutterLoader 可能尚未初始化，
            //    因此这里显式调用 startInitialization / ensureInitializationComplete。
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "overlayMain"
            )
            dartExecutor.executeDartEntrypoint(entrypoint)
        }
        
        // 缓存引擎以便复用
        FlutterEngineCache.getInstance().put("overlay_engine", flutterEngine!!)
        
        // 设置 MethodChannel 用于与主引擎通信
        MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updatePosition" -> {
                    // 处理位置更新
                    result.success(true)
                }
                "updateFontSize" -> {
                    // 处理字号更新
                    result.success(true)
                }
                "updateOpacity" -> {
                    // 处理透明度更新
                    result.success(true)
                }
                "hide" -> {
                    // 隐藏悬浮窗
                    result.success(true)
                }
                "show" -> {
                    // 显示悬浮窗
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
    
    override fun onDestroy() {
        flutterEngine?.destroy()
        FlutterEngineCache.getInstance().remove("overlay_engine")
        flutterEngine = null
        super.onDestroy()
    }
    
    companion object {
        /// 获取缓存的 Flutter Engine
        fun getCachedEngine(): FlutterEngine? {
            return FlutterEngineCache.getInstance().get("overlay_engine")
        }
    }
}