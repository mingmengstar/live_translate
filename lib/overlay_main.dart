import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// 悬浮窗独立引擎入口点
/// 在独立 Isolate 中运行，通过 PlatformDispatcher 接收数据更新
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 设置 PlatformDispatcher 回调以接收来自主引擎的数据
  ui.PlatformDispatcher.instance.onPlatformMessage = _handlePlatformMessage;
  
  // 运行悬浮窗应用
  runApp(const _OverlayApp());
}

void _handlePlatformMessage(String name, ByteData? data, ui.PlatformMessageResponseCallback? callback) {
  if (name == 'live_translate/overlay_data') {
    // 解析数据并更新悬浮窗显示
    // 实际实现中需要解码 data 并更新 UI 状态
  }
  callback?.call(null);
}

class _OverlayApp extends StatelessWidget {
  const _OverlayApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        textTheme: GoogleFonts.notoSansScTextTheme(ThemeData.dark().textTheme),
      ),
      home: const _OverlayRoot(),
    );
  }
}

class _OverlayRoot extends StatefulWidget {
  const _OverlayRoot();

  @override
  State<_OverlayRoot> createState() => _OverlayRootState();
}

class _OverlayRootState extends State<_OverlayRoot> {
  String _originalText = '';
  String _translatedText = '';
  double _fontSize = 18.0;

  @override
  Widget build(BuildContext context) {
    // 悬浮窗内容 - 只有字幕显示，无装饰
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xCC000000), // 80% 黑色半透明
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 原文
            Text(
              _originalText.isEmpty ? '等待语音输入...' : _originalText,
              style: GoogleFonts.notoSansSc(
                color: Colors.white,
                fontSize: _fontSize,
                height: 1.4,
              ),
            ),
            // 译文
            if (_translatedText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                height: 1,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 8),
              Text(
                _translatedText,
                style: GoogleFonts.notoSansSc(
                  color: Colors.greenAccent,
                  fontSize: _fontSize,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}