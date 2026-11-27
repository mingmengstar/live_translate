/// 悬浮窗覆盖层 UI
///
/// 独立的 Flutter 引擎入口点（`main()` 之外的 `overlayMain`），
/// 由 `flutter_screen_overlay` 的 OverlayService attach 到系统悬浮窗口上。
///
/// ## 本文件的边界（很重要）
///
/// **窗口创建/销毁由主 App 的 `OverlayController` 独占管理。**
/// 这里只负责「在已经存在的窗口里画字幕条、响应按钮」，
/// 绝不允许调用 `showOverlay()` / `closeOverlay()`。
///
/// 需要关窗或切位置时，发命令给主 App，由主 App 执行。
///
/// ## 本文件是「无状态渲染器」（本轮重构的核心）
///
/// 这里的 `_fontSize` / `_opacity` / `_sourceText` **都不是权威值**，
/// 只是主 App 推过来的快照。理由：
///
/// overlay 的 widget 树会随着窗口重建而**整体重建**（`onDestroy` 里
/// `detachOverlayView()`，下次 `showOverlay()` 再 `new FlutterView`）。
/// 用户点「切换位置」就会触发一次重建。若设置只活在这个 State 里，
/// 重建后字号会跳回 16、字幕会清空 —— 用户看到的就是「点一下位置，
/// 我调好的字号没了」。
///
/// 所以：
/// - 启动时立刻 `requestSync`，向主 App 要当前设置与状态；
/// - 每次改设置都**同时**告诉主 App（它会持久化）；
/// - 收到主 App 的 `settings` / `state` 消息就覆盖本地快照。
///
/// ## 窗口尺寸假设
///
/// 窗口不是全屏，而是 `OverlayController` 算出来的「字幕条」尺寸
/// （宽 = 屏宽 - 左右边距，高 = 180dp）。因此这里的布局必须
/// **铺满窗口**，不能再套全屏用的 `Align` + 大量边距，否则内容会溢出。
library live_translate.ui.overlay_screen;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:live_translate/core/overlay/overlay_protocol.dart';
import 'package:live_translate/core/overlay/overlay_settings.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart' as overlay;

/// 悬浮窗入口点（必须标记为 vm:entry-point）
///
/// 注意：这个 `@pragma` 只能防止「已进编译图」的函数被 tree-shake，
/// 它**不能**把一份没被任何文件 import 的文件拉进编译图。
/// 真正保证它进 AOT 的是 `lib/main.dart` 里的 import + `kEmbeddedEntrypoints`。
@pragma('vm:entry-point')
void overlayMain() {
  // 设置系统 UI 覆盖样式
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const OverlayApp());
}

class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '实时翻译 - 悬浮窗',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'NotoSansSC',
      ),
      home: const OverlayScreen(),
    );
  }
}

class OverlayScreen extends StatefulWidget {
  const OverlayScreen({super.key});

  @override
  State<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends State<OverlayScreen>
    with WidgetsBindingObserver {
  /// 当前字幕
  String _sourceText = '';
  String _translatedText = '';
  bool _isFinal = false;

  /// 服务是否在运行（主 App 推过来；用于决定是否显示「点击开始」提示）
  bool _serviceRunning = false;

  /// 显示设置（主 App 是权威，这里是快照）
  OverlaySettings _settings = const OverlaySettings();

  /// 数据监听订阅
  StreamSubscription<dynamic>? _dataSubscription;

  /// 防抖定时器（虽然主引擎已做 100ms 节流，这里再加一层保险）
  Timer? _debounceTimer;
  String _pendingSource = '';
  String _pendingTranslated = '';
  bool _pendingFinal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeOverlay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dataSubscription?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  /// 初始化悬浮窗数据监听
  Future<void> _initializeOverlay() async {
    try {
      _dataSubscription = overlay.FlutterScreenOverlay.overlayListener.listen(
        _onDataReceived,
        onError: (Object error) {
          debugPrint('[Overlay] Data stream error: $error');
        },
        onDone: () {
          debugPrint('[Overlay] Data stream closed');
        },
      );

      debugPrint('[Overlay] Initialized and listening for data');

      // 主动要一份当前状态。
      //
      // 不发这条的话，经过「切位置 / 系统回收引擎」之后重建的这个 widget
      // 会停在默认字号 16 / 默认透明度，而主 App 里记的是用户调过的值。
      await _sendCommand(OverlayCommand.requestSync);
    } catch (e, stack) {
      debugPrint('[Overlay] Initialization error: $e\n$stack');
    }
  }

  /// 给主 App 发命令
  Future<void> _sendCommand(OverlayCommand command) async {
    try {
      await overlay.FlutterScreenOverlay.shareData(
        buildCommandMessage(command),
      );
      debugPrint('[Overlay] Sent command: ${command.wire}');
    } catch (e) {
      // 主 App 可能已经退出；发不出去不影响本地渲染
      debugPrint('[Overlay] Send command failed (${command.wire}): $e');
    }
  }

  /// 接收主 App 发来的消息
  ///
  /// 注意字段类型：`shareData()` 走 JSONMessageCodec，反序列化后
  /// 最外层是 `Map<Object?, Object?>`，直接 `as Map<String, dynamic>`
  /// 在部分情况下会抛 cast 异常。这里全部用宽松读取。
  void _onDataReceived(dynamic data) {
    if (data is! Map) {
      debugPrint('[Overlay] Ignored non-map payload: $data');
      return;
    }

    final type = data['type'];
    switch (type) {
      case OverlayMessageType.settings:
        _applySettings(data);
      case OverlayMessageType.state:
        _applyState(data);
      case OverlayMessageType.subtitle:
        _applySubtitle(data);
      default:
        // 兼容旧格式（没有 type 字段，直接就是字幕字段）。
        // 主 App 和 overlay 引擎可能不同步（一个是旧进程），
        // 这时宁可当成字幕渲染，也不要让屏幕一直空着。
        if (data.containsKey('sourceText') ||
            data.containsKey('translatedText')) {
          _applySubtitle(data);
        } else {
          debugPrint('[Overlay] Ignored unknown payload type=$type');
        }
    }
  }

  void _applySettings(Map<Object?, Object?> data) {
    final next = OverlaySettings.fromMap(data);
    if (next == _settings) return;
    debugPrint('[Overlay] Settings applied: $next');
    setState(() => _settings = next);
  }

  void _applyState(Map<Object?, Object?> data) {
    final running = data['serviceRunning'] as bool? ?? false;
    if (running == _serviceRunning) return;
    setState(() => _serviceRunning = running);
  }

  void _applySubtitle(Map<Object?, Object?> data) {
    _pendingSource = data['sourceText'] as String? ?? '';
    _pendingTranslated = data['translatedText'] as String? ?? '';
    _pendingFinal = data['isFinal'] as bool? ?? false;

    // 防抖处理（双重保险，主引擎已有 100ms 节流）
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      setState(() {
        _sourceText = _pendingSource;
        _translatedText = _pendingTranslated;
        _isFinal = _pendingFinal;
      });
    });
  }

  /// 改字号
  ///
  /// 先本地生效（用户立刻看到反馈），再通知主 App 持久化。
  /// 这样即使与主 App 的通信失败，本次窗口生命周期内手感也是对的。
  Future<void> _changeFont({required bool larger}) async {
    final next = larger ? _settings.withLargerFont : _settings.withSmallerFont;
    if (next == _settings) return;
    setState(() => _settings = next);
    await _sendCommand(
      larger ? OverlayCommand.fontIncrease : OverlayCommand.fontDecrease,
    );
  }

  /// 循环透明度
  Future<void> _cycleOpacity() async {
    final next = _settings.withNextOpacity;
    setState(() => _settings = next);
    await _sendCommand(OverlayCommand.cycleOpacity);
  }

  /// 切位置
  ///
  /// 本文件**不能**自己关窗重开（会把承载当前 State 的引擎一起拆掉，
  /// 必然 setState-after-dispose）。所以只发命令，由主 App 执行。
  Future<void> _cyclePosition() async {
    await _sendCommand(OverlayCommand.cyclePosition);
  }

  /// 请求主 App 停止服务（连悬浮窗一起收）
  Future<void> _requestStop() async {
    await _sendCommand(OverlayCommand.stopService);
  }

  /// 仅收起悬浮窗，服务继续跑
  Future<void> _requestHide() async {
    await _sendCommand(OverlayCommand.hideOverlay);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('[Overlay] Lifecycle state: $state');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: AnimatedOpacity(
        opacity: _settings.opacity,
        duration: const Duration(milliseconds: 200),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFinal
                  ? Colors.green.withValues(alpha: 0.5)
                  : Colors.blue.withValues(alpha: 0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
                spreadRadius: 2,
              ),
              BoxShadow(
                color: (_isFinal ? Colors.green : Colors.blue)
                    .withValues(alpha: 0.18),
                blurRadius: 15,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildControlBar(),
                // Expanded：窗口高度固定，内容区吃掉剩余空间；
                // 文字过长时由 Text 的 maxLines + ellipsis 裁剪，
                // 绝不能让 Column 溢出（溢出会在悬浮窗上画出黄黑条纹）。
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                    child: _buildContent(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 内容区：原文 + 译文 / 空状态
  Widget _buildContent() {
    if (_sourceText.isEmpty && _translatedText.isEmpty) {
      return Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.translate_rounded, size: 18, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              _serviceRunning ? '等待语音输入…' : '翻译服务未运行',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: _settings.fontSize * 0.85,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_sourceText.isNotEmpty)
          _buildTextRow(
            label: '原文',
            text: _sourceText,
            color: Colors.white.withValues(alpha: 0.9),
            icon: Icons.mic_rounded,
            maxLines: 2,
          ),
        if (_sourceText.isNotEmpty && _translatedText.isNotEmpty)
          const SizedBox(height: 6),
        if (_translatedText.isNotEmpty)
          _buildTextRow(
            label: '译文',
            text: _translatedText,
            color: Colors.blue[100]!,
            icon: Icons.translate_rounded,
            maxLines: 2,
          ),
      ],
    );
  }

  /// 顶部控制栏
  ///
  /// 按钮分两类，行为有本质区别：
  ///
  /// - **本地可生效**：字号 ±、透明度、位置指示。
  ///   其中位置只是「显示当前在哪」，真正换位置要把命令发回主 App
  ///   重建窗口（`moveOverlay` 改的是像素偏移，不是 gravity）。
  /// - **必须回主 App 执行**：隐藏、停止。
  ///   overlay 自己 closeOverlay 会拆掉自己的引擎。
  Widget _buildControlBar() {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          // 状态指示
          Container(
            width: 18,
            height: 4,
            decoration: BoxDecoration(
              color: _isFinal ? Colors.greenAccent : Colors.blue,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isFinal ? '实时翻译' : '识别中…',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _buildIconButton(
            icon: Icons.text_decrease_rounded,
            onTap: () => _changeFont(larger: false),
            tooltip: '减小字号',
            enabled: _settings.canDecreaseFont,
          ),
          _buildIconButton(
            icon: Icons.text_increase_rounded,
            onTap: () => _changeFont(larger: true),
            tooltip: '增大字号',
            enabled: _settings.canIncreaseFont,
          ),
          _buildIconButton(
            icon: Icons.opacity_rounded,
            onTap: _cycleOpacity,
            tooltip: '调节透明度',
          ),
          // 位置：图标即「当前在哪」，点一下换下一个位置
          _buildIconButton(
            icon: _positionIcon,
            onTap: _cyclePosition,
            tooltip: '切换位置（当前：${_settings.position.label}）',
          ),
          _buildIconButton(
            icon: Icons.visibility_off_rounded,
            onTap: _requestHide,
            tooltip: '收起悬浮窗（服务继续运行）',
          ),
          _buildIconButton(
            icon: Icons.stop_circle_outlined,
            onTap: _requestStop,
            tooltip: '停止翻译',
          ),
        ],
      ),
    );
  }

  IconData get _positionIcon {
    switch (_settings.position) {
      case SubtitlePosition.top:
        return Icons.vertical_align_top_rounded;
      case SubtitlePosition.center:
        return Icons.vertical_align_center_rounded;
      case SubtitlePosition.bottom:
        return Icons.vertical_align_bottom_rounded;
    }
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    bool enabled = true,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 17,
            color: enabled ? Colors.grey[300] : Colors.grey[700],
          ),
        ),
      ),
    );
  }

  /// 文本行（标签 + 内容）
  Widget _buildTextRow({
    required String label,
    required String text,
    required Color color,
    required IconData icon,
    required int maxLines,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 13, color: Colors.blue[300]),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: _settings.fontSize * 0.65,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                text,
                style: TextStyle(
                  color: color,
                  fontSize: _settings.fontSize,
                  height: 1.35,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}