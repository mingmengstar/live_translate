/// 悬浮窗 ↔ 主 App 的消息协议（**两个引擎共用的唯一事实来源**）
///
/// 为什么单独抽一个文件：
/// 主 App 和悬浮窗是**两个独立的 FlutterEngine**，各自跑各自编译出来的代码。
/// 如果两边各写一份字面量（`'sourceText'`、`'cmd'`、`'stop'`...），
/// 改一边漏一边时编译器**不会报错** —— 表现是「按钮点了没反应」，
/// 而要排查这个得同时盯着 overlay 和 main 两份 logcat。
///
/// 所以：字段名和命令名只允许在这里定义一次，两边都 import 它。
///
/// ## 通道复用说明（读插件源码后确认）
///
/// 插件只提供一条双向通道：
/// `BasicMessageChannel("x-slayer/overlay_messenger", JSONMessageCodec)`。
///
/// - 主 App 调 `shareData()` → 插件 `FlutterOverlayWindowPlugin.onMessage`
///   → 转发进 **overlay** 引擎的 Dart 侧；
/// - overlay 调 `shareData()` → `OverlayService` 里的 handler
///   → `WindowSetup.messenger.send()` → 投递到 **主 App** Dart 侧的
///   `overlayListener`。
///
/// 两个方向共用同一个 channel，但底层转发路径不同，**不会回环**。
/// 既然共用一个通道，就只能靠消息里的 `type` 字段区分方向。
library live_translate.core.overlay.overlay_protocol;

/// 消息类型（放在 `type` 字段里）
class OverlayMessageType {
  OverlayMessageType._();

  /// 主 → overlay：字幕内容
  static const String subtitle = 'subtitle';

  /// 主 → overlay：显示设置（字号 / 透明度 / 位置）
  static const String settings = 'settings';

  /// 主 → overlay：服务运行状态
  static const String state = 'state';

  /// 双向：控制命令（overlay → 主 是用户操作；主 → overlay 只有 requestSync）
  static const String command = 'command';
}

/// 用户能触发的动作
///
/// 命名刻意区分「谁执行」：
/// - [fontIncrease] / [fontDecrease] / [cycleOpacity] 由 overlay 自己就能改，
///   但**仍然要通知主 App**，否则主 App 记的设置会和屏幕上的不一致，
///   下次重建窗口就会「跳回去」。
/// - [stopService] / [hideOverlay] 必须由主 App 执行 ——
///   窗口生命周期归 `OverlayController` 独占（历史 P1，勿破）。
enum OverlayCommand {
  /// 让主 App 停下翻译服务
  stopService,

  /// 让主 App 收起悬浮窗（overlay 自己 closeOverlay 会销毁当前 State）
  hideOverlay,

  /// 字号变大
  fontIncrease,

  /// 字号变小
  fontDecrease,

  /// 循环切换透明度
  cycleOpacity,

  /// 循环切换位置
  cyclePosition,

  /// overlay 刚起来，请求主 App 把当前设置和状态推过来
  ///
  /// 这条不发，overlay 引擎被系统回收后再重建时，界面会停在默认值
  /// （字号 16 / 透明度 0.95），而主 App 以为用户设的是别的值。
  requestSync,
}

/// [OverlayCommand] ↔ 线上字符串
///
/// 手写映射而不是 `name`，是为了让「改 Dart 枚举名」不会悄悄改掉协议。
extension OverlayCommandWire on OverlayCommand {
  String get wire {
    switch (this) {
      case OverlayCommand.stopService:
        return 'stopService';
      case OverlayCommand.hideOverlay:
        return 'hideOverlay';
      case OverlayCommand.fontIncrease:
        return 'fontIncrease';
      case OverlayCommand.fontDecrease:
        return 'fontDecrease';
      case OverlayCommand.cycleOpacity:
        return 'cycleOpacity';
      case OverlayCommand.cyclePosition:
        return 'cyclePosition';
      case OverlayCommand.requestSync:
        return 'requestSync';
    }
  }
}

/// 从线上字符串解析命令，未知值返回 null（不抛异常）
///
/// 为什么不抛：两端版本可能短暂不一致（比如主 App 已更新、overlay 引擎
/// 还是旧进程）。此时宁可忽略一条未知命令，也不要让悬浮窗崩掉。
OverlayCommand? overlayCommandFromWire(String? wire) {
  if (wire == null) return null;
  for (final c in OverlayCommand.values) {
    if (c.wire == wire) return c;
  }
  return null;
}

/// 构造「命令」消息
Map<String, Object?> buildCommandMessage(OverlayCommand command) => {
      'type': OverlayMessageType.command,
      'cmd': command.wire,
    };

/// 从收到的消息里取出命令（不是命令消息则返回 null）
OverlayCommand? readCommand(Map<Object?, Object?> data) {
  if (data['type'] != OverlayMessageType.command) return null;
  return overlayCommandFromWire(data['cmd'] as String?);
}
