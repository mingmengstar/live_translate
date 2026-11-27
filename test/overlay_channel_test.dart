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

  group('悬浮窗 Dart 入口点必须进 AOT 快照', () {
    // 事故复现（v0.3.4）：
    // flutter_screen_overlay 原生侧用
    //   new DartEntrypoint(bundlePath, "overlayMain")
    // 按**名字**去 AOT 快照里找入口点。但 overlay_screen.dart 当时
    // 全项目零 import，Dart 编译器按 import 图决定编译单元，于是整份
    // 文件没被编译 —— libapp.so 里连它的字符串常量都不存在。
    // 后果：APK 构建成功、单测全过、OverlayService 也起来了，
    // 但悬浮窗口里永远是白屏。行为测试抓不到，只能做源码断言。
    late String mainDart;
    late String overlayScreen;

    setUpAll(() {
      mainDart = stripDartComments(
        File('lib/main.dart').readAsStringSync(),
      );
      overlayScreen = stripDartComments(
        File('lib/ui/overlay_screen.dart').readAsStringSync(),
      );
    });

    test('main.dart 必须 import overlay_screen.dart（否则文件不进编译图）', () {
      expect(
        mainDart.contains("import 'package:live_translate/ui/overlay_screen.dart'"),
        true,
        reason: '没有这条 import，overlay_screen.dart 完全不参与编译，'
            'release APK 里不会有 overlayMain',
      );
    });

    test('main.dart 必须以真实引用持有 overlayMain（不能只在注释里提到）', () {
      expect(
        mainDart.contains('overlayMain'),
        true,
        reason: '仅 import 不引用，入口点仍可能被 tree-shake',
      );
    });

    test('保留 overlayMain 的引用不能放在 assert 里', () {
      // assert 在 release 构建会被整体剥离。若「防止 tree-shake」的引用
      // 写在 assert 中，debug 下测试全绿，release APK 依然丢入口点。
      final assertBlocks = RegExp(r'assert\s*\(\s*\(\)\s*\{[\s\S]*?\}\s*\(\s*\)\s*\)');
      for (final m in assertBlocks.allMatches(mainDart)) {
        expect(
          m.group(0)!.contains('kEmbeddedEntrypoints'),
          false,
          reason: '入口点保留表不能在 assert 里被引用，release 会被剥离',
        );
      }
    });

    test('overlayMain 必须带 @pragma(vm:entry-point)', () {
      expect(
        overlayScreen.contains("@pragma('vm:entry-point')"),
        true,
        reason: '缺少 entry-point 注解，AOT 会把它当死代码删掉',
      );
      // 注解必须紧贴函数声明（中间只允许空白行）
      expect(
        RegExp(r"@pragma\('vm:entry-point'\)\s*\n\s*void\s+overlayMain\s*\(")
            .hasMatch(overlayScreen),
        true,
        reason: '@pragma 必须直接修饰 overlayMain 函数',
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