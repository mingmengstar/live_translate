import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:quick_settings_with_flutter_plugins/quick_settings.dart';
import 'package:live_translate/core/service/translation_service.dart';
import 'package:live_translate/core/tile/quick_settings_tile.dart';
import 'package:live_translate/ui/home_screen.dart';
// 悬浮窗入口所在文件。这个 import 不是「可选的整洁代码」——
// 它是 release APK 里悬浮窗能不能显示的前提条件，删掉就等于悬浮窗消失。
// 详见下面 kEmbeddedEntrypoints 的注释。
import 'package:live_translate/ui/overlay_screen.dart' show overlayMain;

/// 嵌入到本 App 内的「额外 Dart 入口点」保留表。
///
/// ## 为什么需要这个东西（踩过的 P0，勿删）
///
/// `flutter_screen_overlay` 的原生侧是这样启动悬浮窗 UI 的：
///
/// ```java
/// new DartExecutor.DartEntrypoint(flutterLoader().findAppBundlePath(), "overlayMain")
/// ```
///
/// 也就是说，它在**运行时按字符串名字**去 AOT 快照里找 `overlayMain`。
///
/// 而 Dart 的编译器（`dart compile aot`）是按 **import 图**决定编译单元的：
/// 没有任何文件 import 的文件根本不参与编译，`@pragma('vm:entry-point')`
/// 只是「不要因为看起来没人调用而把它当垃圾删掉」的保命符，它**不能**
/// 把一份没进编译图的文件拉进来。
///
/// 历史事故（v0.3.4）：`overlay_screen.dart` 全项目零 import，
/// 于是 `libapp.so` 里连它的字符串常量都不存在（用 `utf-16-le` 反查
/// `[Overlay] Lifecycle state` 命中 0 次）。表现是：APK 构建成功、
/// 单测全过、悬浮窗 Service 也起来了，但窗口里永远是空的 / 白屏。
///
/// 所以这里用两件事同时保证：
/// 1. 文件头部的 `import ... overlay_screen.dart` → 让它进入编译图；
/// 2. 下面的 const 表持有 `overlayMain` 的 tear-off，并在 `main()` 里被读取
///    → 让 AOT 认为它是一个「可能被调用的活函数」，连同
///    `OverlayApp` / `OverlayScreen` 整棵 widget 树一起保留下来。
///
/// 加新入口点（比如 widget/后台 isolate）时也往这个表里加。
const List<void Function()> kEmbeddedEntrypoints = <void Function()>[
  overlayMain,
];

void main() {
  // 确保 Flutter 绑定初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 触碰一次上面那张表，防止它被当作未使用的常量整条 tree-shake 掉。
  //
  // 注意这里**不能用 `assert(...)`**：assert 在 release 构建里会被整体剥离，
  // 那样「引用」就只在 debug 下存在，release APK 依然会丢掉这个入口点 ——
  // 正是本项目这个 P0 的翻版。必须用一条 release 下也会执行的语句。
  // debugPrint 在 release 中仍保留，顺带在 logcat 留一行可核对的痕迹。
  debugPrint(
    '[Entrypoints] embedded dart entrypoints: ${kEmbeddedEntrypoints.length}',
  );
  
  // 设置 QuickSettings 回调（必须在 runApp 之前调用）
  QuickSettings.setup(
    onTileClicked: onTileClicked,
    onTileAdded: onTileAdded,
    onTileRemoved: onTileRemoved,
  );
  
  runApp(const LiveTranslateApp());
}

class LiveTranslateApp extends StatefulWidget {
  const LiveTranslateApp({super.key});
  
  @override
  State<LiveTranslateApp> createState() => _LiveTranslateAppState();
}

class _LiveTranslateAppState extends State<LiveTranslateApp> {
  late final TranslationService _translationService;
  late final QuickSettingsTileService _tileService;
  bool _isInitialized = false;
  String? _initError;
  
  @override
  void initState() {
    super.initState();
    _translationService = TranslationService();
    _tileService = QuickSettingsTileService();
    _initializeApp();
  }
  
  Future<void> _initializeApp() async {
    try {
      // 初始化翻译服务（注册并启动 Mock 引擎）
      await _translationService.initialize();
      
      // 初始化快捷设置磁贴
      await _tileService.initialize(
        translationService: _translationService,
        onStateChanged: () {
          if (mounted) setState(() {});
        },
      );
      
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e, stack) {
      debugPrint('[LiveTranslateApp] Initialization error: $e\n$stack');
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _isInitialized = true; // 仍然显示 UI，但会显示错误
        });
      }
    }
  }
  
  @override
  void dispose() {
    _translationService.dispose();
    _tileService.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    // 初始化期间显示加载界面
    if (!_isInitialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '实时翻译',
        theme: _buildDarkTheme(),
        home: const _LoadingScreen(),
      );
    }
    
    // 初始化失败显示错误界面
    if (_initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '实时翻译',
        theme: _buildDarkTheme(),
        home: _ErrorScreen(error: _initError!, onRetry: _initializeApp),
      );
    }
    
    // 正常运行
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _translationService),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '实时翻译',
        theme: _buildDarkTheme(),
        home: const HomeScreen(),
      ),
    );
  }
  
  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00B0FF),
        secondary: Color(0xFF00E5A0),
        surface: Color(0xFF1E1E1E),
        surfaceContainerHighest: Color(0xFF121212),
        error: Colors.redAccent,
        onPrimary: Colors.white,
        onSecondary: Colors.black,
        onSurface: Colors.white,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      cardTheme: CardThemeData(
        color: const Color(0xFF1E1E1E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white10),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00B0FF),
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white10),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00B0FF), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white10,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        preferBelow: false,
      ),
    );
  }
}

/// 加载界面
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.translate_rounded,
                color: Colors.blue,
                size: 48,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '实时翻译',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '正在初始化引擎...',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 32),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              strokeWidth: 3,
            ),
          ],
        ),
      ),
    );
  }
}

/// 错误界面
class _ErrorScreen extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  
  const _ErrorScreen({required this.error, required this.onRetry});
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.redAccent,
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '初始化失败',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  error,
                  style: TextStyle(
                    color: Colors.redAccent[200],
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}