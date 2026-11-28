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
///
/// ## v0.5.0：为什么「窗口不显示」修不掉（根因）
///
/// 旧实现有一个**致命的信任错误**：它把 `showOverlay()` 返回成功
/// 当成「窗口已经显示」，置 `_isShowing = true`。但读插件源码可知：
///
/// ```java
/// } else if (call.method.equals("showOverlay")) {
///     ...
///     try {
///         context.startService(intent);   // 只是「投递了一个 Intent」
///     } catch (Exception e) { ... }
///     result.success(null);              // ← 立刻返回成功
/// }
/// ```
///
/// `startService()` 成功**只代表系统接受了这个 Intent**。真正把 FlutterView
/// 挂到 WindowManager 上是在 `OverlayService.onStartCommand()` 里做的，
/// 而它可能在这里失败（全部被 catch 住、`stopSelf()`、**不通知 Dart 侧**）：
///
/// - `BadTokenException`：Activity 在服务启动瞬间被销毁（热启动常见）；
/// - `WindowManager$BadTokenException`：悬浮窗权限被系统临时收回；
/// - `FlutterEngineCache` 里的引擎被低内存回收（`engine == null` → 直接 stopSelf）；
/// - `startForeground()` 抛 `ForegroundServiceStartNotAllowedException`
///   （应用刚进后台，Android 12+ 的后台启动限制）。
///
/// 这些情况下的表现完全一致：**Dart 侧收到 success，屏幕上什么都没有**，
/// 而且 `_isShowing` 已经被置 true —— 之后每一次 `show()` 都走
/// `if (_isShowing) return success;` 直接短路，**永远不会重试**。
/// 用户只能杀进程重开。这就是「点开始没反应、点重新显示也没反应」的来源。
///
/// ### 修法
///
/// 用插件自己提供的 `isActive()`（原生侧读 `OverlayService.isRunning`）
/// 做**产物级确认**：`showOverlay()` 之后轮询它，只有真的 true 才算成功。
/// 这是唯一能区分「Intent 投递成功」和「View 真的挂上去了」的判据。
///
/// 轮询而不是单次查询的原因：`startService()` 是异步的，
/// `result.success` 返回时 `onCreate` 可能还没跑，立刻查必然是 false。
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
    this.code,
  });

  /// 是否成功显示
  final bool ok;

  /// 失败原因（可直接展示给用户）
  final String? reason;

  /// 机器可读的错误码，便于日志检索
  ///
  /// - `PERMISSION`：没有「显示在其他应用上层」权限
  /// - `SERVICE_START`：前台服务起不来（manifest / 后台启动限制）
  /// - `NOT_ATTACHED`：服务起来了但 FlutterView 没挂上窗口
  /// - `EXCEPTION`：其它异常
  final String? code;

  static const OverlayShowResult success = OverlayShowResult(ok: true);

  @override
  String toString() =>
      ok ? 'OverlayShowResult(ok)' : 'OverlayShowResult(fail: $code/$reason)';
}

/// 悬浮字幕条的高度（dp）
///
/// 需要容纳：顶部 34dp 控制栏 + 原文一行 + 译文一行 + 内边距。
/// 实际渲染内容超过这个高度时，overlay 侧会裁剪（maxLines + ellipsis），
/// 因此这里是「上限」而不是「精确值」。
const double kOverlayHeightDp = 180.0;

/// 悬浮字幕条左右各留的边距（dp）
const double kOverlaySidePaddingDp = 12.0;

/// 字幕条宽度上限（dp），平板上避免拉成一条超宽的横条
const double kOverlayMaxWidthDp = 720.0;

/// 确认窗口真的挂上去的轮询参数
///
/// 总等待 1.6s（200ms × 8）。为什么不是更长：
/// 冷启动 overlayMain 约 5s，但那是**引擎**启动，`addView` 是引擎启动前
/// 就完成的；正常路径下 200ms 内 `isRunning` 就会是 true。
/// 等太久会让 UI 卡在「正在显示悬浮窗…」。
const Duration _kVerifyInterval = Duration(milliseconds: 200);
const int _kVerifyAttempts = 8;

class OverlayController {
  OverlayController._();

  static final OverlayController instance = OverlayController._();

  /// 与 MainActivity 通信的权限通道（复用已有实现，不新增原生代码）
  static const MethodChannel _permissionChannel =
      MethodChannel('live_translate/permissions');

  /// 悬浮窗是否已由本控制器显示（**仅为乐观标记**）
  ///
  /// 注意：这个字段**不能**作为「窗口真的在屏幕上」的依据，
  /// 它只用于短路重复调用。真正的判据永远走 [isActuallyActive]。
  /// 详见文件头「为什么窗口不显示修不掉」一节。
  bool _isShowing = false;

  /// 对外语义：最近一次 show 成功
  bool get isShowing => _isShowing;

  /// 并发保护：正在 show 的过程中再次调用 show 直接返回
  bool _showInFlight = false;

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
  ///
  /// ## 为什么会「挂起等用户回来」（BUG-2 修复的关键）
  ///
  /// 旧实现发一次 `requestOverlayPermission` 就等返回值。但原生侧现在
  /// 的行为是「跳系统设置页 → 用户手动开开关 → 回 App 才复查」，
  /// 所以这里必须在**用户回来之后**再确认一次权限，否则会立刻拿到
  /// 一个「还没授权」的 false，把用户刚点开的开关判成失败。
  ///
  /// 做法：发起请求后轮询 [hasPermission]，最多等 60 秒。
  /// 这段时间 App 在后台，Dart 定时器依然会跑，回来就能立刻拿到 true。
  Future<bool> requestPermission() async {
    try {
      await _permissionChannel.invokeMethod<bool>('requestOverlayPermission');
    } on PlatformException catch (e) {
      log('[Overlay] 请求悬浮窗权限失败: $e', name: 'OverlayController');
      return false;
    } on MissingPluginException {
      return false;
    }

    // 原生侧已经授权（无需跳转）或刚跳转完：先查一次，省掉无谓等待
    if (await hasPermission()) return true;

    // 等用户去系统设置里打开开关再回来。
    //
    // 每 400ms 查一次（不重发请求），最多 60 秒：
    // - 400ms 足够快，用户一回来就能继续，不会觉得卡住；
    // - 不用 100ms：设置页期间 App 在后台，频繁跨通道调用没意义。
    const pollInterval = Duration(milliseconds: 400);
    const maxWait = Duration(seconds: 60);
    final deadline = DateTime.now().add(maxWait);

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (await hasPermission()) {
        log('[Overlay] 用户已授予悬浮窗权限', name: 'OverlayController');
        return true;
      }
    }

    log(
      '[Overlay] 等待悬浮窗权限超时（${maxWait.inSeconds}s）',
      name: 'OverlayController',
    );
    return false;
  }

  /// 原生侧是否真的认为窗口活着
  ///
  /// 读的是插件 `OverlayService.isRunning`（同一进程的静态字段）。
  /// 这是**唯一**能区分「Intent 投递成功」与「View 真的挂上去了」的判据。
  Future<bool> isActuallyActive() async {
    try {
      return await overlay.FlutterScreenOverlay.isActive();
    } catch (e) {
      // 平台通道不可用（单元测试 / 非 Android）：保守返回 false，
      // 调用方会走「无法确认」分支，不会误报成功。
      log('[Overlay] isActive 查询失败: $e', name: 'OverlayController');
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
  ///
  /// 7. **必须验证窗口真的挂上了**（v0.5.0）。见文件头注释。
  Future<OverlayShowResult> show({
    SubtitlePosition? position,
  }) async {
    // 已经在显示：不要盲目相信自己，向原生确认一次。
    // 原生说不在 → 说明窗口被系统回收了（低内存 / 后台限制），
    // 清掉乐观标记继续往下走，而不是短路返回一个假的成功。
    if (_isShowing) {
      if (await isActuallyActive()) {
        return OverlayShowResult.success;
      }
      log(
        '[Overlay] 本地标记为已显示，但原生侧窗口已消失，重新创建',
        name: 'OverlayController',
      );
      _isShowing = false;
    }

    // 并发保护：连续点两次「开始」不该起两个窗口
    if (_showInFlight) {
      return const OverlayShowResult(
        ok: false,
        code: 'IN_FLIGHT',
        reason: '悬浮窗正在显示中，请稍候',
      );
    }
    _showInFlight = true;

    try {
      return await _showInternal(position);
    } finally {
      _showInFlight = false;
    }
  }

  Future<OverlayShowResult> _showInternal(SubtitlePosition? position) async {
    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) {
        return const OverlayShowResult(
          ok: false,
          code: 'PERMISSION',
          reason: '未获得「显示在其他应用上层」权限',
        );
      }
    }

    // LayoutParams 收的是物理像素，这里把逻辑尺寸换算过去
    final dpr = PlatformDispatcher.instance.views.isEmpty
        ? 1.0
        : PlatformDispatcher.instance.views.first.devicePixelRatio;
    final size = _targetSizeDp();
    final alignment =
        (position ?? OverlaySettingsStore.instance.current.position).alignment;

    try {
      await overlay.FlutterScreenOverlay.showOverlay(
        height: (size.height * dpr).round(),
        width: (size.width * dpr).round(),
        alignment: alignment,
        flag: overlay.OverlayFlag.defaultFlag,
        // 显式指定通知可见性：插件原生侧 `WindowSetup.setNotificationVisibility`
        // 直接对传入值调 `name.equalsIgnoreCase(...)`，**没有 null 保护**。
        // 依赖 Dart 默认值虽然当前可用，但显式传参可以彻底排除
        // 「原生收到 null → NPE → onCreate 崩溃 → 静默 stopSelf」这条路径。
        visibility: overlay.NotificationVisibility.visibilitySecret,
        overlayTitle: '实时翻译正在运行',
        overlayContent: '字幕显示中，点字幕条上的按钮可调节',
        enableDrag: false,
        wakeScreen: false,
      );

      // ---- 关键：确认窗口真的挂上了 ----
      //
      // showOverlay 的 success 只代表 Intent 投递成功。这里轮询原生
      // 的 isRunning，只有真的 true 才敢报成功。
      final mounted = await _waitUntilActive();
      if (!mounted) {
        _isShowing = false;
        log(
          '[Overlay] showOverlay 返回成功，但窗口始终未挂载'
          '（OverlayService.isRunning=false）。'
          '常见原因：后台启动限制 / BadToken / 引擎被回收。',
          name: 'OverlayController',
        );
        return const OverlayShowResult(
          ok: false,
          code: 'NOT_ATTACHED',
          reason: '悬浮窗服务已启动，但窗口没有挂到屏幕上。'
              '请确认已授予「显示在其他应用上层」权限，'
              '并把 App 切回前台后重试',
        );
      }

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
      return OverlayShowResult(ok: false, code: e.code, reason: reason);
    } catch (e) {
      _isShowing = false;
      log('[Overlay] showOverlay 异常: $e', name: 'OverlayController');
      return OverlayShowResult(
        ok: false,
        code: 'EXCEPTION',
        reason: '悬浮窗启动异常: $e',
      );
    }
  }

  /// 轮询 `isActive()`，直到窗口真的挂上或超时
  ///
  /// 为什么需要轮询：`startService()` 是异步的，`showOverlay()` 的
  /// `result.success` 返回时 `OverlayService.onCreate()` 可能还没执行，
  /// 立刻查必然是 false（会误判成失败）。
  Future<bool> _waitUntilActive() async {
    for (var i = 0; i < _kVerifyAttempts; i++) {
      if (await isActuallyActive()) return true;
      await Future<void>.delayed(_kVerifyInterval);
    }
    // 最后一轮：避免刚好在最后一次 delay 之后才就绪
    return isActuallyActive();
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
  ///
  /// ## 关窗是异步的
  ///
  /// `closeOverlay()` → `context.stopService()` → `onDestroy()` 也是异步的。
  /// 紧接着 `showOverlay()` 时，旧的 `onStartCommand` 可能还在跑，
  /// 插件会用 `windowManager != null || flutterView != null` 判断并先 detach
  /// 再重建，所以不会冲突；但**必须等一下**让 `isRunning` 回落，
  /// 否则新的验证会读到旧的 true 而误报成功。
  Future<OverlayShowResult> reposition(SubtitlePosition position) async {
    await hide();
    // 等原生侧 isRunning 真的变 false（最多 600ms），
    // 避免新窗口的验证读到旧窗口的残留状态。
    for (var i = 0; i < 3; i++) {
      if (!await isActuallyActive()) break;
      await Future<void>.delayed(_kVerifyInterval);
    }
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
            '或缺少前台服务权限，也可能是应用在后台被系统限制启动）';
      default:
        return '悬浮窗启动失败：${e.code}${e.message == null ? '' : ' / ${e.message}'}';
    }
  }
}