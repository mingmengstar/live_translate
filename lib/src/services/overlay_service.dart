import 'package:flutter/services.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';
import 'package:flutter_screen_overlay/src/models/overlay_position.dart';
import 'package:flutter_screen_overlay/src/overlay_config.dart';

class OverlayService {

  Future<void> initialize() async {
    // 原生服务已在 onCreate 中建立通道
    // 预热 overlay 引擎
    await FlutterScreenOverlay.warmUp();
  }

  Future<void> showOverlay({double fontSize = 18, int left = 0, int top = 0}) async {
    try {
      await FlutterScreenOverlay.showOverlay(
        width: WindowSize.matchParent,
        height: WindowSize.fullCover,
        alignment: OverlayAlignment.topLeft,
        enableDrag: true,
        startPosition: OverlayPosition(left.toDouble(), top.toDouble()),
        wakeScreen: true,
      );
    } on PlatformException catch (e) {
      print('OverlayService showOverlay error: ${e.message}');
    }
  }

  Future<void> hideOverlay() async {
    try {
      await FlutterScreenOverlay.closeOverlay();
    } on PlatformException catch (e) {
      print('OverlayService hideOverlay error: ${e.message}');
    }
  }

  Future<void> updateSubtitle({String original = '', String translated = '', double fontSize = 18}) async {
    try {
      // 通过 BasicMessageChannel 发送字幕数据
      await FlutterScreenOverlay.shareData({
        'original': original,
        'translated': translated,
        'fontSize': fontSize,
      });
    } on PlatformException catch (e) {
      print('OverlayService updateSubtitle error: ${e.message}');
    }
  }

  Future<void> updateSettings({double fontSize = 18}) async {
    // 字体大小等设置通过 shareData 传递
  }

  // 权限相关
  static Future<bool> isPermissionGranted() async {
    return await FlutterScreenOverlay.isPermissionGranted();
  }

  static Future<bool?> requestPermission() async {
    return await FlutterScreenOverlay.requestPermission();
  }
}