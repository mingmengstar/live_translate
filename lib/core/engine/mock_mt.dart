/// Mock MT 引擎实现
/// 用于开发调试，给文本加前缀返回，模拟流式翻译输出
library live_translate.core.engine.mock_mt;

import 'dart:developer';
import 'package:live_translate/core/i18n/language_registry.dart';

import 'mt_engine.dart';

class MockMT implements MTEngine {
  @override
  final String engineId = 'mock_mt';

  @override
  final String displayName = 'Mock MT (测试用)';

  @override
  bool isInitialized = false;

  @override
  bool isRunning = false;

  @override
  String sourceLanguage = 'en';

  @override
  String targetLanguage = 'ja';

  // 语言对从 [LanguageRegistry] 派生（12 种语言共 132 个方向）。
  //
  // 旧实现只硬编码了 8 个方向，`en→ru` / `ja→fr` 这类组合会直接抛
  // `ArgumentError`。Mock 是「引擎接口契约的参考实现」，
  // 它接受的方向必须与真实引擎一致，否则单测通过、真机崩。
  @override
  final List<LanguagePair> supportedLanguagePairs = LanguageRegistry.mtPairs;

  // Mock 翻译映射表
  static final Map<String, Map<String, String>> _translations = {
    'en': {'ja': '【日】', 'zh': '【中】', 'ko': '【韩】'},
    'ja': {'en': '[EN] ', 'zh': '【中】', 'ko': '【韩】'},
    'zh': {'en': '[EN] ', 'ja': '【日】', 'ko': '【韩】'},
    'ko': {'en': '[EN] ', 'ja': '【日】', 'zh': '【中】'},
  };

  @override
  Future<void> initialize({
    String? modelPath,
    String sourceLang = 'en',
    String targetLang = 'ja',
    Map<String, dynamic> config = const {},
  }) async {
    // 模拟初始化延迟
    await Future.delayed(const Duration(milliseconds: 200));

    sourceLanguage = sourceLang;
    targetLanguage = targetLang;
    isInitialized = true;
    log('[MockMT] Initialized: $sourceLang -> $targetLang', name: 'MockMT');
  }

  @override
  Future<void> translateStream({
    required String text,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    if (!isInitialized) {
      onError(StateError('MockMT not initialized'), StackTrace.current);
      return;
    }

    isRunning = true;
    final startTime = DateTime.now();

    try {
      // 获取前缀
      final prefix =
          _translations[sourceLanguage]?[targetLanguage] ?? '[TRANS] ';
      final translatedText = '$prefix$text';

      // 模拟流式输出：分 3 个片段返回
      final chunks = _splitIntoChunks(translatedText, 3);

      for (int i = 0; i < chunks.length; i++) {
        // 模拟网络/推理延迟
        await Future.delayed(Duration(milliseconds: 150 + (i * 50)));

        if (!isRunning) break; // 允许取消

        onChunk(
          MTChunk(
            text: chunks[i],
            isFinal: i == chunks.length - 1,
            chunkIndex: i,
          ),
        );
      }

      final latency = DateTime.now().difference(startTime);
      final result = MTResult(
        sourceText: text,
        translatedText: translatedText,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        latency: latency,
      );

      onComplete(result);
      log(
        '[MockMT] Translated: "$text" -> "$translatedText" (${latency.inMilliseconds}ms)',
        name: 'MockMT',
      );
    } catch (e, stack) {
      onError(e, stack);
    } finally {
      isRunning = false;
    }
  }

  /// 将文本分割成多个片段，模拟流式输出
  List<String> _splitIntoChunks(String text, int chunkCount) {
    if (text.length <= chunkCount) {
      return [text];
    }

    final chunkSize = (text.length / chunkCount).ceil();
    final chunks = <String>[];

    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? text.length : (start + chunkSize);
      if (start < text.length) {
        chunks.add(text.substring(start, end));
      }
    }

    return chunks;
  }

  @override
  Future<MTResult> translate(String text) async {
    if (!isInitialized) {
      throw StateError('MockMT not initialized');
    }

    final startTime = DateTime.now();
    final prefix = _translations[sourceLanguage]?[targetLanguage] ?? '[TRANS] ';
    final translatedText = '$prefix$text';
    final latency = DateTime.now().difference(startTime);

    return MTResult(
      sourceText: text,
      translatedText: translatedText,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
      latency: latency,
    );
  }

  @override
  Future<void> switchLanguagePair(String sourceLang, String targetLang) async {
    final pair = supportedLanguagePairs.firstWhere(
      (p) => p.source == sourceLang && p.target == targetLang,
      orElse: () => throw ArgumentError(
        'Unsupported language pair: $sourceLang -> $targetLang',
      ),
    );

    sourceLanguage = pair.source;
    targetLanguage = pair.target;
    log(
      '[MockMT] Language pair switched to: $sourceLanguage -> $targetLanguage',
      name: 'MockMT',
    );
  }

  @override
  Future<void> dispose() async {
    isRunning = false;
    isInitialized = false;
    log('[MockMT] Disposed', name: 'MockMT');
  }

  @override
  Map<String, dynamic> getStatus() {
    return {
      'engineId': engineId,
      'displayName': displayName,
      'isInitialized': isInitialized,
      'isRunning': isRunning,
      'sourceLanguage': sourceLanguage,
      'targetLanguage': targetLanguage,
      'supportedPairs': supportedLanguagePairs.map((p) => '$p').toList(),
    };
  }
}
