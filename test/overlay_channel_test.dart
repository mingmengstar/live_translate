/// 悬浮窗链路防回归测试
///
/// 每条断言都对应一次真实事故：「APK 构建成功、单测全过，
/// 但真机上悬浮窗根本不出现」。这类问题出在「原生声明缺失」和
/// 「调用点缺失」，行为测试拿不到 Android manifest，所以这里用源码断言。
///
/// ⚠️ 匹配前**必须先剥掉注释**：本项目的注释里大量引用了
/// `showOverlay(` / `WindowSize.matchParent` / `OverlayFlutterEngine`
/// 这些名字（解释「为什么不能这么写」），直接用 `contains` 会误判。
library live_translate.test.overlay_channel_test;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉 Dart 的 `//`、`///` 行注释与 `/* */` 块注释
///
/// 只为断言服务，不追求完美解析（不处理字符串里出现 `//` 的极端情况）。
String stripDartComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}

/// 去掉 XML 注释 `<!-- -->`
String stripXmlComments(String src) =>
    src.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

void main() {
  group('悬浮窗 Android 声明', () {
    late String manifest;

    setUpAll(() {
      final f = File('android/app/src/main/AndroidManifest.xml');
      expect(f.existsSync(), true, reason: '找不到 AndroidManifest.xml');
      // 剥掉注释，只看真正生效的声明
      manifest = stripXmlComments(f.readAsStringSync());
    });

    test('必须声明插件的 OverlayService', () {
      // 插件自己的 manifest 只有 permission，没有 <service>（见其 README）。
      // 漏声明的后果：showOverlay() 抛 PlatformException(SERVICE_START)，
      // 悬浮窗永远不出现 —— 本项目最隐蔽的一个坑。
      expect(
        manifest.contains(
          'flutter.overlay.window.flutter_overlay_window.OverlayService',
        ),
        true,
        reason: '缺少 OverlayService 声明，showOverlay() 会直接失败',
      );
    });

    test('OverlayService 必须是 specialUse 前台服务类型', () {
      // Android 14+ 要求前台服务声明类型；specialUse 必须配
      // FOREGROUND_SERVICE_SPECIAL_USE 权限，否则 startForeground() 抛
      // SecurityException。
      expect(
        manifest.contains('android:foregroundServiceType="specialUse"'),
        true,
      );
      expect(
        manifest.contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
        true,
        reason: 'specialUse 服务缺该权限会在 Android 14+ 直接崩',
      );
    });

    test('不应残留已废弃的 OverlayFlutterEngine 声明', () {
      // 该 Service 从未被 startService，通道 live_translate/overlay
      // 在 lib/ 里零调用，是死代码。留着会让人误以为悬浮窗走它。
      expect(
        manifest.contains('OverlayFlutterEngine'),
        false,
        reason: 'OverlayFlutterEngine 是死代码，其声明应已移除',
      );
    });
  });

  group('悬浮窗控制权归属', () {
    test('主 App 必须真的调用 showOverlay（否则窗口不会出现）', () {
      // 历史问题：全项目只有 overlay_screen.dart 内部调 showOverlay，
      // 等于「悬浮窗自己显示自己」，主 App 从不触发 → 真机永远看不到。
      final controller = stripDartComments(
        File('lib/core/overlay/overlay_controller.dart').readAsStringSync(),
      );
      expect(
        controller.contains('showOverlay('),
        true,
        reason: 'OverlayController 必须真正调用 showOverlay',
      );

      // 且必须由 Service 生命周期驱动
      final service = stripDartComments(
        File('lib/core/service/translation_service.dart').readAsStringSync(),
      );
      expect(
        service.contains('_syncOverlayWithServiceState'),
        true,
        reason: '服务启停必须同步悬浮窗显隐',
      );
    });

    test('overlay 进程不得自行 show/close 窗口', () {
      // 窗口生命周期归主 App 独占。overlay 里再调会导致状态互相打架，
      // 且 closeOverlay() 会销毁当前引擎 → setState after dispose。
      final overlayScreen = stripDartComments(
        File('lib/ui/overlay_screen.dart').readAsStringSync(),
      );
      expect(
        overlayScreen.contains('showOverlay('),
        false,
        reason: 'overlay_screen.dart 不应调用 showOverlay',
      );
      expect(
        overlayScreen.contains('closeOverlay('),
        false,
        reason: 'overlay_screen.dart 不应调用 closeOverlay',
      );
    });
  });

  group('悬浮窗尺寸', () {
    test('字幕条不能用 matchParent 全屏（会挡住整屏触摸）', () {
      // showOverlay 的 height/width 直接进 WindowManager.LayoutParams，
      // 不经过 dp 换算。全屏 + defaultFlag = 整屏触摸都被拦截，
      // 用户回到任何 App 都点不动。
      final controller = stripDartComments(
        File('lib/core/overlay/overlay_controller.dart').readAsStringSync(),
      );
      expect(
        controller.contains('WindowSize.matchParent'),
        false,
        reason: '全屏悬浮窗会拦截整屏触摸，必须用字幕条尺寸',
      );
      expect(
        controller.contains('devicePixelRatio'),
        true,
        reason: 'LayoutParams 收物理像素，必须乘 devicePixelRatio',
      );
    });
  });
}