/// 悬浮窗显示设置的持久化（字号 / 透明度 / 位置）
///
/// ## 为什么这些值必须由主 App 持有，而不是让 overlay 自己记
///
/// 悬浮窗的窗口是**可以被销毁重建**的，有两条真实路径：
///
/// 1. 用户点「切换位置」—— 位置是 `showOverlay()` 的 `alignment`，
///    只在创建窗口时生效（`moveOverlay()` 只改 x/y 偏移，不改 gravity），
///    所以要换位置就必须关窗重开；
/// 2. 系统低内存回收 overlay 引擎，或用户从最近任务划掉 App 后重开。
///
/// 一旦重建，`_OverlayScreenState` 是全新的，字段回到初始值。
/// 如果设置只存在 State 里，用户刚调好的字号会当场跳回 16。
///
/// 所以：**主 App 是设置的唯一持有者**，overlay 每次起来都先
/// `requestSync` 向主 App 要一份当前值。
///
/// 这条路还有个额外好处：设置能跨进程重启存活（写进 shared_preferences），
/// 用户下次开 App 还是上次的字号。
library live_translate.core.overlay.overlay_settings;

import 'dart:ui' show Color;

import 'package:flutter_screen_overlay/flutter_screen_overlay.dart' as overlay;
import 'package:shared_preferences/shared_preferences.dart';

/// 字幕条停靠位置（这是**产品语义**，不是插件的 alignment）
///
/// 只暴露三档而不是插件那 9 档：字幕条是宽横条，
/// 左上/右中等位置会把一半屏幕挡住，属于负体验。
enum SubtitlePosition {
  top,
  center,
  bottom;

  /// 映射到插件的 gravity
  overlay.OverlayAlignment get alignment {
    switch (this) {
      case SubtitlePosition.top:
        return overlay.OverlayAlignment.topCenter;
      case SubtitlePosition.center:
        return overlay.OverlayAlignment.center;
      case SubtitlePosition.bottom:
        return overlay.OverlayAlignment.bottomCenter;
    }
  }

  /// 给用户看的中文名
  String get label {
    switch (this) {
      case SubtitlePosition.top:
        return '顶部';
      case SubtitlePosition.center:
        return '居中';
      case SubtitlePosition.bottom:
        return '底部';
    }
  }

  /// 下一档（底部 → 顶部 → 居中 → 底部，循环）
  ///
  /// 顺序按「用户最常用的在两头」排：默认底部，点一下就跳到顶部，
  /// 再点回中间。这样 1 次点击就能从底部切到顶部，不用点两下。
  SubtitlePosition get next {
    switch (this) {
      case SubtitlePosition.bottom:
        return SubtitlePosition.top;
      case SubtitlePosition.top:
        return SubtitlePosition.center;
      case SubtitlePosition.center:
        return SubtitlePosition.bottom;
    }
  }

  String get wire => name;

  static SubtitlePosition fromWire(String? wire) {
    for (final p in SubtitlePosition.values) {
      if (p.wire == wire) return p;
    }
    return SubtitlePosition.bottom;
  }
}

/// 双语字幕的上下顺序
///
/// 悬浮窗是「原文 + 译文」两行。哪一行在上面，不同用户习惯完全不同：
/// - 学语言的人希望「先看原文，再对照译文」→ 原文在上；
/// - 只看译文的人希望「译文显眼」→ 译文在上。
///
/// 这是纯展示偏好，与识别/翻译链路无关，所以只影响渲染顺序。
enum SubtitleOrder {
  /// 原文在上，译文在下（默认，符合「读原文再对照」的习惯）
  sourceFirst,

  /// 译文在上，原文在下（只关注译文时更省眼力）
  targetFirst;

  String get label {
    switch (this) {
      case SubtitleOrder.sourceFirst:
        return '原文在上';
      case SubtitleOrder.targetFirst:
        return '译文在上';
    }
  }

  String get wire => name;

  static SubtitleOrder fromWire(String? wire) {
    for (final o in SubtitleOrder.values) {
      if (o.wire == wire) return o;
    }
    return SubtitleOrder.sourceFirst;
  }
}

/// 字幕条背景预设色（**背景与前景成对**，避免白底白字）
///
/// ## 为什么用固定预设而不是取色器
///
/// 1. 悬浮窗只有 34dp 高的控制栏，放不下取色器；
/// 2. 真正需要的是「在白底 App 上要深色、在深色视频上要亮色」这种
///    粗粒度切换，8 个预设已经够覆盖；
/// 3. 固定枚举能保证 `wire` 稳定 —— 主 App 与 overlay 是两个独立引擎，
///    颜色若按 `0xAARRGGBB` 裸整数传，两边解析格式不一致时
///    **不会报错**，只会画出一个看不懂的颜色（本项目最怕的失败模式）。
///
/// 每个预设都自带配套前景色，所以「纯白背景 + 黑字」这种组合是内建保证的，
/// 不需要调用方自己判断亮度。
enum SubtitleBgColor {
  /// 午夜黑（默认）：最不干扰的形态
  midnight('午夜黑', 0xFF101418, 0xFFF2F6FA),

  /// 石板灰
  slate('石板灰', 0xFF2A2F36, 0xFFFFFFFF),

  /// 纯白：最显眼，主要用于「先确认窗口到底出没出来」
  snow('纯白', 0xFFF7FAFC, 0xFF101418),

  /// 青色：深色内容上极度可见
  cyan('青色', 0xFF00D9E8, 0xFF00202A),

  /// 琥珀：暖色高对比
  amber('琥珀', 0xFFFFC400, 0xFF201800),

  /// 深蓝
  navy('深蓝', 0xFF1B3B8F, 0xFFF2F6FA),

  /// 深绿
  forest('深绿', 0xFF0B5D3B, 0xFFF2F6FA),

  /// 品红
  magenta('品红', 0xFFB0136B, 0xFFF7FAFC);

  const SubtitleBgColor(this.label, this._bgArgb, this._fgArgb);

  /// 给用户看的中文名
  final String label;

  final int _bgArgb;
  final int _fgArgb;

  /// 背景色
  Color get background => Color(_bgArgb);

  /// 配套前景色（文字 / 图标 / 边框基准）
  Color get foreground => Color(_fgArgb);

  String get wire => name;

  /// 下一档（循环）
  SubtitleBgColor get next {
    final all = SubtitleBgColor.values;
    return all[(index + 1) % all.length];
  }

  static SubtitleBgColor fromWire(String? wire) {
    for (final c in SubtitleBgColor.values) {
      if (c.wire == wire) return c;
    }
    return SubtitleBgColor.midnight;
  }
}

/// 悬浮窗显示设置
class OverlaySettings {
  const OverlaySettings({
    this.fontSize = defaultFontSize,
    this.opacity = defaultOpacity,
    this.position = SubtitlePosition.bottom,
    this.order = SubtitleOrder.sourceFirst,
    this.backgroundColor = SubtitleBgColor.midnight,
  });

  // ---- 取值范围 ----
  //
  // 这些常量是 overlay 和主 App 的**共同契约**：
  // overlay 用它来 clamp 和判断按钮是否禁用，主 App 用它来校验收到的值。
  // 两端不一致的话，会出现「按钮能点但点了没变化」这种难查的现象。
  static const double minFontSize = 12.0;
  static const double maxFontSize = 24.0;
  static const double fontSizeStep = 1.0;
  static const double defaultFontSize = 16.0;

  static const double minOpacity = 0.25;
  static const double maxOpacity = 1.0;

  /// 背景不透明度的默认值：**必须是不透明**
  ///
  /// 旧默认 0.95 在深色内容上几乎等于看不见。用户排查「悬浮窗到底有没有
  /// 出来」时，一个实心块是第一判据，所以默认拉满。
  static const double defaultOpacity = 1.0;

  /// 背景不透明度循环档位（升序）
  ///
  /// ## v0.9.2：从 4 档扩到 5 档，下限 0.6 → 0.25
  ///
  /// 用户原话是「太挡视线了 → 再透明点」。旧档位最低 0.6，
  /// 在小屏上仍然盖住小半个屏幕，等于没得选。
  ///
  /// 现在最低 0.25，且**只作用于背景**：文字始终不透明，
  /// 所以「几乎全透明背景 + 清晰文字」是可达状态 —— 这才是字幕该有的形态。
  ///
  /// 不提供 0.0：完全透明的背景下只剩边框两根线，用户会以为是渲染 bug。
  static const List<double> opacityLevels = [0.25, 0.4, 0.6, 0.8, 1.0];

  final double fontSize;

  /// 背景不透明度（**只作用于背景，不作用于文字**）
  final double opacity;

  final SubtitlePosition position;

  /// 双语字幕的上下顺序（原文在上 / 译文在上）
  final SubtitleOrder order;

  /// 背景色预设（自带配套前景色，保证对比度）
  final SubtitleBgColor backgroundColor;

  OverlaySettings copyWith({
    double? fontSize,
    double? opacity,
    SubtitlePosition? position,
    SubtitleOrder? order,
    SubtitleBgColor? backgroundColor,
  }) {
    return OverlaySettings(
      fontSize: fontSize ?? this.fontSize,
      opacity: opacity ?? this.opacity,
      position: position ?? this.position,
      order: order ?? this.order,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }

  /// 字号 +1（到达上限就不动）
  OverlaySettings get withLargerFont =>
      copyWith(fontSize: (fontSize + fontSizeStep).clamp(minFontSize, maxFontSize));

  /// 字号 -1（到达下限就不动）
  OverlaySettings get withSmallerFont =>
      copyWith(fontSize: (fontSize - fontSizeStep).clamp(minFontSize, maxFontSize));

  /// 透明度切到下一档
  ///
  /// 找不到当前值落在哪一档时（比如从持久化读到了 0.7），
  /// 取「比它大的第一档」，保证每次点击都有肉眼可见的变化。
  OverlaySettings get withNextOpacity {
    final levels = opacityLevels;
    final idx = levels.indexWhere((l) => (opacity - l).abs() < 0.05);
    if (idx >= 0) {
      return copyWith(opacity: levels[(idx + 1) % levels.length]);
    }
    for (final l in levels) {
      if (l > opacity) return copyWith(opacity: l);
    }
    return copyWith(opacity: levels.first);
  }

  OverlaySettings get withNextPosition => copyWith(position: position.next);

  /// 背景色切到下一档（循环）
  OverlaySettings get withNextBackground =>
      copyWith(backgroundColor: backgroundColor.next);

  bool get canIncreaseFont => fontSize < maxFontSize - 0.001;
  bool get canDecreaseFont => fontSize > minFontSize + 0.001;

  /// 序列化为消息载荷（同时用于持久化，两者字段一致省一次映射）
  Map<String, Object?> toMap() => {
        'fontSize': fontSize,
        'opacity': opacity,
        'position': position.wire,
        'order': order.wire,
        'backgroundColor': backgroundColor.wire,
      };

  /// 从不可信来源解析
  ///
  /// 消息来自 JSONMessageCodec，数字可能落地成 `int`（当值是整数时），
  /// 直接 `as double` 会抛 type cast 异常 —— 这个坑在本项目
  /// `overlay_screen.dart` 的注释里已经记过一次。统一用 `num` 读再转。
  ///
  /// 任何字段非法都退回默认值，绝不抛异常：设置读坏了不该让悬浮窗崩。
  factory OverlaySettings.fromMap(Map<Object?, Object?> map) {
    final rawFont = map['fontSize'];
    final rawOpacity = map['opacity'];
    final font = rawFont is num
        ? rawFont.toDouble().clamp(minFontSize, maxFontSize)
        : defaultFontSize;
    final opa = rawOpacity is num
        ? rawOpacity.toDouble().clamp(minOpacity, maxOpacity)
        : defaultOpacity;
    return OverlaySettings(
      fontSize: font,
      opacity: opa,
      position: SubtitlePosition.fromWire(map['position'] as String?),
      order: SubtitleOrder.fromWire(map['order'] as String?),
      backgroundColor: SubtitleBgColor.fromWire(map['backgroundColor'] as String?),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OverlaySettings &&
      (other.fontSize - fontSize).abs() < 0.001 &&
      (other.opacity - opacity).abs() < 0.001 &&
      other.position == position &&
      other.order == order &&
      other.backgroundColor == backgroundColor;

  @override
  int get hashCode => Object.hash(
        fontSize.toStringAsFixed(2),
        opacity.toStringAsFixed(2),
        position,
        order,
        backgroundColor,
      );

  @override
  String toString() =>
      'OverlaySettings(font=$fontSize, bgOpacity=$opacity, '
      'pos=${position.wire}, order=${order.wire}, '
      'bg=${backgroundColor.wire})';
}

/// 设置的读写（单例，带内存缓存）
///
/// 读路径会非常频繁（每次 overlay 起来都要一份），所以内存缓存是必需的；
/// 写路径只在用户点按钮时发生，直接落盘没有性能问题。
class OverlaySettingsStore {
  OverlaySettingsStore._();

  static final OverlaySettingsStore instance = OverlaySettingsStore._();

  static const String _kFontSize = 'overlay.font_size';
  static const String _kOpacity = 'overlay.opacity';
  static const String _kPosition = 'overlay.position';
  static const String _kOrder = 'overlay.order';
  static const String _kBackground = 'overlay.background_color';

  OverlaySettings _cached = const OverlaySettings();
  bool _loaded = false;

  /// 当前设置（同步读，永远有值）
  OverlaySettings get current => _cached;

  /// 从持久化恢复（幂等）
  ///
  /// 读取失败（测试环境 / 插件不可用）时静默保留默认值，
  /// 与 `ModelStorage.loadPreferences` 的处理方式保持一致。
  Future<OverlaySettings> load() async {
    if (_loaded) return _cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cached = OverlaySettings(
        fontSize: (prefs.getDouble(_kFontSize) ?? OverlaySettings.defaultFontSize)
            .clamp(OverlaySettings.minFontSize, OverlaySettings.maxFontSize),
        opacity: (prefs.getDouble(_kOpacity) ?? OverlaySettings.defaultOpacity)
            .clamp(OverlaySettings.minOpacity, OverlaySettings.maxOpacity),
        position: SubtitlePosition.fromWire(prefs.getString(_kPosition)),
        order: SubtitleOrder.fromWire(prefs.getString(_kOrder)),
        backgroundColor:
            SubtitleBgColor.fromWire(prefs.getString(_kBackground)),
      );
      _loaded = true;
    } catch (_) {
      // 保持默认值，但**不**置 _loaded，下次还能再试一次
    }
    return _cached;
  }

  /// 保存并更新缓存
  ///
  /// 先更新内存再落盘：即使用户立刻关掉 App，本次运行的界面也已经对了。
  Future<void> save(OverlaySettings settings) async {
    _cached = settings;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kFontSize, settings.fontSize);
      await prefs.setDouble(_kOpacity, settings.opacity);
      await prefs.setString(_kPosition, settings.position.wire);
      await prefs.setString(_kOrder, settings.order.wire);
      await prefs.setString(_kBackground, settings.backgroundColor.wire);
    } catch (_) {
      // 落盘失败只影响下次启动，本次运行不受影响
    }
  }

  /// 仅用于测试：重置缓存
  void debugReset() {
    _cached = const OverlaySettings();
    _loaded = false;
  }
}