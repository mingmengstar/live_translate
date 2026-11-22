package com.example.live_translate

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class TranslateTileService : TileService() {

    companion object {
        const val CHANNEL = "live_translate/tile"
        private var isTileActive = false
    }

    override fun onCreate() {
        super.onCreate()
        val flutterEngine = FlutterEngineCache.getInstance().get("live_translate_engine")
            ?: FlutterEngine(this).also { FlutterEngineCache.getInstance().put("live_translate_engine", it) }
        if (!flutterEngine.dartExecutor.isExecutingDart) {
            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setTileState" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    isTileActive = active
                    updateTileState()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        isTileActive = !isTileActive
        updateTileState()
        
        // 通知 Dart 端切换状态
        val flutterEngine = FlutterEngineCache.getInstance().get("live_translate_engine")
        if (flutterEngine != null) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onTileToggled", mapOf("active" to isTileActive))
        }
    }

    private fun updateTileState() {
        val tile = qsTile
        tile.state = if (isTileActive) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = if (isTileActive) "实时同传: 开" else "实时同传: 关"
        tile.updateTile()
    }
}