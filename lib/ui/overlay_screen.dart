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
/// ## 窗口尺寸假设
///
/// 窗口不是全屏，而是 `OverlayController` 算出来的「字幕条」尺寸
/// （宽 = 屏宽 - 左右边距，高 = 180dp）。因此这里的布局必须
/// **铺满窗口**，不能再套全屏用的 `Align` + 大量边距，否则内容会溢出。
library live_translate.ui.overlay_screen;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart' as overlay;

/// 悬浮窗入口点（必须标记为 vm:entry-point）
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
  /// 字号可调范围
  static const double _minFontSize = 12.0;
  static const double _maxFontSize = 24.0;

  /// 当前显示的文本
  String _sourceText = '';
  String _translatedText = '';
  bool _isFinal = false;

  /// 字号设置（默认 16sp）
  double _fontSize = 16.0;

  /// 透明度
  double _opacity = 0.95;

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
      // 监听主引擎发送的共享数据
      _dataSubscription = overlay.FlutterScreenOverlay.overlayListener.listen(
        (dynamic data) => _onDataReceived(data),
        onError: (error) {
          debugPrint('[Overlay] Data stream error: $error');
        },
        onDone: () {
          debugPrint('[Overlay] Data stream closed');
        },
      );

      debugPrint('[Overlay] Initialized and listening for data');
    } catch (e, stack) {
      debugPrint('[Overlay] Initialization error: $e\n$stack');
    }
  }

  /// 接收主引擎发送的数据
  ///
  /// 注意字段类型：`shareData()` 走 JSONMessageCodec，反序列化后
  /// 最外层是 `Map<Object?, Object?>`，直接
  /// `as Map<String, dynamic>` 在部分情况下会抛 cast 异常。
  /// 这里改用宽松读取。
  void _onDataReceived(dynamic data) {
    if (data is! Map) {
      debugPrint('[Overlay] Ignored non-map payload: $data');
      return;
    }

    final sourceText = data['sourceText'] as String? ?? '';
    final translatedText = data['translatedText'] as String? ?? '';
    final isFinal = data['isFinal'] as bool? ?? false;

    // 防抖处理（双重保险，主引擎已有 100ms 节流）
    _pendingSource = sourceText;
    _pendingTranslated = translatedText;
    _pendingFinal = isFinal;

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

  /// 更新字号
  void _updateFontSize(double size) {
    final next = size.clamp(_minFontSize, _maxFontSize);
    if (next == _fontSize) return;
    setState(() => _fontSize = next);
  }

  /// 更新透明度
  void _updateOpacity(double opacity) {
    setState(() => _opacity = opacity.clamp(0.3, 1.0));
  }

  /// 循环切换透明度
  void _cycleOpacity() {
    const levels = [0.6, 0.8, 0.95, 1.0];
    final currentIndex = levels.indexWhere((l) => (_opacity - l).abs() < 0.05);
    final nextIndex = (currentIndex + 1) % levels.length;
    _updateOpacity(levels[nextIndex]);
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
        opacity: _opacity,
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
              '等待语音输入…',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: _fontSize * 0.85,
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
  /// 只保留「真能生效且不会破坏窗口生命周期」的三个操作：
  /// 字号 -、字号 +、透明度循环。
  ///
  /// 为什么没有「隐藏」按钮：悬浮窗是一块 180dp 高的实体窗口，
  /// 单纯把内容变透明**仍然会拦截整条区域的触摸**（用户会在屏幕
  /// 底部点不动任何东西）。要真正隐藏必须关窗口，而关窗口属于
  /// 主 App 的职责（见文件头注释）。停止/隐藏请回主 App 操作。
  ///
  /// 为什么没有「切换位置」按钮：位置是 `showOverlay()` 的
  /// `alignment`（gravity）参数，只在创建窗口时生效；
  /// `moveOverlay()` 改的是 `params.x/y` 像素偏移，不是 gravity，
  /// 在 overlay 进程里用它「假装」换位置会与主 App 记录的状态不一致。
  /// 位置选择将随「反向控制通道」一起实现。
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
            onTap: () => _updateFontSize(_fontSize - 1),
            tooltip: '减小字号',
            enabled: _fontSize > _minFontSize,
          ),
          _buildIconButton(
            icon: Icons.text_increase_rounded,
            onTap: () => _updateFontSize(_fontSize + 1),
            tooltip: '增大字号',
            enabled: _fontSize < _maxFontSize,
          ),
          _buildIconButton(
            icon: Icons.opacity_rounded,
            onTap: _cycleOpacity,
            tooltip: '调节透明度',
          ),
        ],
      ),
    );
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
                  fontSize: _fontSize * 0.65,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                text,
                style: TextStyle(
                  color: color,
                  fontSize: _fontSize,
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