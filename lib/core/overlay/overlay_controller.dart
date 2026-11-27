/// 悬浮窗控制器
///
/// 这是**主 App 侧唯一**允许操作悬浮窗的地方。
///
/// 为什么需要单独一层：
/// 1. `flutter_screen_overlay` 的 API 全部是静态方法且会抛 PlatformException，
///    散落在 UI 里会让「窗口没弹出来」这类问题极难定位。集中一层后，
///    每次失败都能拿到 `error.code`（例如 `SERVICE_START` = manifest 没声明
///    OverlayService），可以直接在界面上告诉用户原因。
/// 2. 悬浮窗开关必须和「服务是否运行」严格同步：服务启动 → showOverlay，
///    服务停止 → closeOverlay。放在 UI 的按钮回调里迟早会漏。
/// 3. 悬浮窗权限是 Android 的特殊权限（SYSTEM_ALERT_WINDOW），必须走
///    MainActivity 的 startActivityForResult 路径才能可靠拿到授权结果；
///    插件自带的 requestPermission 依赖 Activity 绑定，在 Service 场景不可靠。
library live_translate.core.overlay.overlay_controller;

import 'dart:developer';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart' as overlay;
import 'package:live_translate/core/overlay/overlay_settings.dart';

/// 悬浮窗显示结果
class OverlayShowResult {
  const OverlayShowResult({
    required this.ok,
    this.reason,
  });

  /// 是否成功显示
  final bool ok;

  /// 失败原因（可直接展示给用户）
  final String? reason;

  static const OverlayShowResult success = OverlayShowResult(ok: true);

  @override
  String toString() => ok ? 'OverlayShowResult(ok)' : 'OverlayShowResult(fail: $reason)';
}

/// 悬浮字幕条的高度（dp）
///
/// 需要容纳：顶部 40dp 控制栏 + 原文一行 + 译文一行 + 内边距。
/// 实际渲染内容超过这个高度时，overlay 侧会裁剪（maxLines + ellipsis），
/// 因此这里是「上限」而不是「精确值」。
const double kOverlayHeightDp = 180.0;

/// 悬浮字幕条左右各留的边距（dp）
const double kOverlaySidePaddingDp = 12.0;

/// 字幕条宽度上限（dp），平板上避免拉成一条超宽的横条
const double kOverlayMaxWidthDp = 720.0;

class OverlayController {
  OverlayController._();

  static final OverlayController instance = OverlayController._();

  /// 与 MainActivity 通信的权限通道（复用已有实现，不新增原生代码）
  static const MethodChannel _permissionChannel =
      MethodChannel('live_translate/permissions');

  /// 悬浮窗是否已由本控制器显示
  bool _isShowing = false;

  bool get isShowing => _isShowing;

  /// 检查悬浮窗权限（不弹框）
  Future<bool> hasPermission() async {
    try {
      final granted =
          await _permissionChannel.invokeMethod<bool>('checkOverlayPermission');
      return granted == true;
    } on PlatformException catch (e) {
      log('[Overlay] 检查悬浮窗权限失败: $e', name: 'OverlayController');
      return false;
    } on MissingPluginException {
      // 单元测试 / 非 Android 环境
      return false;
    }
  }

  /// 请求悬浮窗权限（会跳到系统设置页）
  Future<bool> requestPermission() async {
    try {
      final granted = await _permissionChannel
          .invokeMethod<bool>('requestOverlayPermission');
      return granted == true;
    } on PlatformException catch (e) {
      log('[Overlay] 请求悬浮窗权限失败: $e', name: 'OverlayController');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 预创建悬浮窗引擎（降低首次显示延迟）
  ///
  /// 失败不抛异常：这纯属性能优化，失败也不该阻断主流程。
  Future<void> warmUp() async {
    try {
      await overlay.FlutterScreenOverlay.warmUp();
    } catch (e) {
      log('[Overlay] warmUp 失败（不影响功能）: $e', name: 'OverlayController');
    }
  }

  /// 计算字幕条的目标尺寸（dp）
  ///
  /// 宽度跟随屏幕但左右留边、并设上限，避免平板上一根超长横条；
  /// 拿到屏幕尺寸失败时（如单元测试）退化为固定值，不抛异常。
  ({double width, double height}) _targetSizeDp() {
    double screenWidthDp;
    try {
      final view = PlatformDispatcher.instance.views.first;
      screenWidthDp = view.physicalSize.width / view.devicePixelRatio;
    } catch (_) {
      // 无视图（测试环境）/ 异常：给一个常见手机宽度
      screenWidthDp = 400.0;
    }
    final width = (screenWidthDp - kOverlaySidePaddingDp * 2)
        .clamp(240.0, kOverlayMaxWidthDp);
    return (width: width, height: kOverlayHeightDp);
  }

  /// 显示悬浮字幕窗口
  ///
  /// 设计要点（都是踩过的坑，改动前请读完）：
  ///
  /// 1. **窗口尺寸必须是「字幕条」，不能用 matchParent 全屏**。
  ///    `showOverlay()` 的 height/width 会被 `OverlayService` 直接塞进
  ///    `WindowManager.LayoutParams`（`WindowSize.matchParent = -1` 即
  ///    MATCH_PARENT），**不经过 dp 换算**。全屏窗口 + `defaultFlag`
  ///    意味着整个屏幕都被这个悬浮窗盖住，所有触摸事件都会落在它身上，
  ///    用户回到任何 App 都点不动 —— 这是最容易被忽略的严重问题。
  ///    因此这里固定成一条居中的字幕条尺寸。
  ///
  /// 2. **尺寸要乘 devicePixelRatio**：LayoutParams 用的是像素，Dart 侧
  ///    算出来的是逻辑像素（dp）。不换算的话，在 3x 屏上字幕条会小到只剩
  ///    三分之一高度。
  ///
  /// 3. `defaultFlag`：不可获取焦点（不抢输入法），但**可以接收触摸**，
  ///    否则字幕条上的字号 / 透明度 / 关闭按钮全部点不动。
  ///    （`clickThrough` 会让触摸穿透，那样按钮也点不到，勿用。）
  ///
  /// 4. `enableDrag: false`：位置由设置里的 [SubtitlePosition] 决定，
  ///    避免用户误拖后与状态不一致。
  ///
  /// 5. `wakeScreen: false`：翻译是被动旁路，不该点亮锁屏。
  ///
  /// 6. **位置来自 `settings.position`**：`showOverlay()` 的 `alignment`
  ///    只在创建窗口时生效，`moveOverlay()` 只改 x/y 像素偏移、不改
  ///    gravity。所以「换位置」必然是一次关窗 + 开窗（见 [reposition]）。
  Future<OverlayShowResult> show({
    SubtitlePosition? position,
  }) async {
    if (_isShowing) {
      return OverlayShowResult.success;
    }

    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) {
        return const OverlayShowResult(
          ok: false,
          reason: '未获得「显示在其他应用上层」权限',
        );
      }
    }

    // LayoutParams 收的是物理像素，这里把逻辑尺寸换算过去
    final dpr = PlatformDispatcher.instance.views.isEmpty
        ? 1.0
        : PlatformDispatcher.instance.views.first.devicePixelRatio;
    final size = _targetSizeDp();
    final alignment = (position ?? OverlaySettingsStore.instance.current.position)
        .alignment;

    try {
      await overlay.FlutterScreenOverlay.showOverlay(
        height: (size.height * dpr).round(),
        width: (size.width * dpr).round(),
        alignment: alignment,
        flag: overlay.OverlayFlag.defaultFlag,
        overlayTitle: '实时翻译正在运行',
        overlayContent: '字幕显示中，点字幕条上的按钮可调节',
        enableDrag: false,
        wakeScreen: false,
      );
      _isShowing = true;
      log(
        '[Overlay] 悬浮窗已显示 '
        '(${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}dp, dpr=$dpr)',
        name: 'OverlayController',
      );
      return OverlayShowResult.success;
    } on PlatformException catch (e) {
      _isShowing = false;
      final reason = _describePlatformError(e);
      log(
        '[Overlay] showOverlay 失败: code=${e.code} message=${e.message}',
        name: 'OverlayController',
      );
      return OverlayShowResult(ok: false, reason: reason);
    } catch (e) {
      _isShowing = false;
      log('[Overlay] showOverlay 异常: $e', name: 'OverlayController');
      return OverlayShowResult(ok: false, reason: '悬浮窗启动异常: $e');
    }
  }

  /// 关闭悬浮字幕窗口
  ///
  /// 刻意**不**做 `if (!_isShowing) return` 的短路：
  /// `_isShowing` 只是本对象的内存标记，而窗口可能已被系统回收、或
  /// 用户从最近任务划掉 App 后残留。此时标记是 true 但窗口其实没了，
  /// 短路就会让「本次的关闭意图」被忽略。`closeOverlay()` 在窗口不存在时
  /// 本身是安全的（插件里判断了 `OverlayService.isRunning`），代价很低。
  Future<void> hide() async {
    try {
      await overlay.FlutterScreenOverlay.closeOverlay();
    } catch (e) {
      // 关闭失败不影响后续流程：服务可能已被系统回收
      log('[Overlay] closeOverlay 失败: $e', name: 'OverlayController');
    } finally {
      _isShowing = false;
    }
  }

  /// 换一个位置显示（关窗 + 重开）
  ///
  /// ## 为什么必须关窗重开，而不是 moveOverlay
  ///
  /// 位置在 Android 侧是 `WindowManager.LayoutParams.gravity`
  /// （插件 `showOverlay()` 的 `alignment` 参数）。而
  /// `moveOverlay(x, y)` 只改 `params.x / params.y` —— 那是**相对当前
  /// gravity 的偏移**，改它不会把窗口从底部挪到顶部。
  ///
  /// 想换 gravity，插件没暴露对应接口，只能 `closeOverlay()` + `showOverlay()`。
  ///
  /// ## 代价可控（实测过源码，不是猜的）
  ///
  /// 看起来「关窗重开」很重，但：
  /// - `OverlayService.onDestroy()` 只做 `detachOverlayView()` 和
  ///   `stopSelf()`，**不会**把引擎从 `FlutterEngineCache` 里移除；
  /// - 所以下次 `showOverlay()` 拿到的还是同一个热引擎，
  ///   **不会**触发 overlayMain 冷启动（否则要等约 5s）。
  ///
  /// ## 但 widget 树会重建
  ///
  /// `detachOverlayView()` 会 `new FlutterView(...)`，
  /// 因此 `_OverlayScreenState` 是全新的 —— 字号、透明度、当前字幕都归零。
  /// 这正是 `overlay_screen.dart` 被写成「无状态渲染器」的原因：
  /// 它起来后会发 `requestSync` 向主 App 要回完整的当前状态。
  ///
  /// 因此本方法**只负责窗口**，不负责把设置推过去 ——
  /// 那是 `TranslationService` 在 `requestSync` 里做的事。
  Future<OverlayShowResult> reposition(SubtitlePosition position) async {
    await hide();
    return show(position: position);
  }

  /// 把悬浮窗错误码翻译成用户能看懂的一句话
  ///
  /// `SERVICE_START` 是历史上最容易踩的坑：它几乎总是意味着
  /// `AndroidManifest.xml` 里少了 OverlayService 声明，或者前台服务类型
  /// 没声明 specialUse 权限。必须把这句话讲清楚，否则用户只会看到「失败」。
  String _describePlatformError(PlatformException e) {
    switch (e.code) {
      case 'PERMISSION':
        return '缺少「显示在其他应用上层」权限，请在系统设置中开启';
      case 'SERVICE_START':
        return '悬浮窗服务启动失败（通常是 APK 未声明 OverlayService '
            '或缺少前台服务权限）';
      default:
        return '悬浮窗启动失败：${e.code}${e.message == null ? '' : ' / ${e.message}'}';
    }
  }
}
