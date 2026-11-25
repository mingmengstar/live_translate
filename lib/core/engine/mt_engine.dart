/// MT 引擎抽象接口
/// 负责源语言到目标语言的翻译
library live_translate.core.engine.mt_engine;

abstract interface class MTEngine {
  /// 引擎唯一标识符
  String get engineId;
  
  /// 引擎显示名称
  String get displayName;
  
  /// 是否已初始化
  bool get isInitialized;
  
  /// 是否正在运行
  bool get isRunning;
  
  /// 当前源语言
  String get sourceLanguage;
  
  /// 当前目标语言
  String get targetLanguage;
  
  /// 支持的语言对列表
  List<LanguagePair> get supportedLanguagePairs;
  
  /// 初始化引擎
  /// [modelPath] 模型文件路径（可选）
  /// [sourceLang] 源语言
  /// [targetLang] 目标语言
  /// [config] 额外配置参数
  Future<void> initialize({
    String? modelPath,
    String sourceLang = 'en',
    String targetLang = 'ja',
    Map<String, dynamic> config = const {},
  });
  
  /// 翻译文本（流式）
  /// [text] 待翻译文本
  /// [onChunk] 流式翻译片段回调
  /// [onComplete] 翻译完成回调
  /// [onError] 错误回调
  Future<void> translateStream({
    required String text,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  });
  
  /// 翻译文本（一次性）
  Future<MTResult> translate(String text);
  
  /// 切换语言对
  Future<void> switchLanguagePair(String sourceLang, String targetLang);
  
  /// 释放资源
  Future<void> dispose();
  
  /// 获取引擎状态信息
  Map<String, dynamic> getStatus();
}

/// 语言对
class LanguagePair {
  final String source;
  final String target;
  final String displayName;
  
  const LanguagePair({
    required this.source,
    required this.target,
    required this.displayName,
  });
  
  @override
  String toString() => '$source -> $target';
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LanguagePair &&
          runtimeType == other.runtimeType &&
          source == other.source &&
          target == other.target;
  
  @override
  int get hashCode => source.hashCode ^ target.hashCode;
}

/// MT 翻译片段（流式输出）
class MTChunk {
  final String text;
  final bool isFinal;
  final int chunkIndex;
  
  const MTChunk({
    required this.text,
    required this.isFinal,
    required this.chunkIndex,
  });
  
  @override
  String toString() => 'MTChunk(text: $text, isFinal: $isFinal, index: $chunkIndex)';
}

/// MT 翻译最终结果
class MTResult {
  final String sourceText;
  final String translatedText;
  final String sourceLanguage;
  final String targetLanguage;
  final Duration latency;
  final bool isFromCache;
  
  const MTResult({
    required this.sourceText,
    required this.translatedText,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.latency,
    this.isFromCache = false,
  });
  
  @override
  String toString() => 
      'MTResult($sourceLanguage->$targetLanguage: "$sourceText" -> "$translatedText", latency: ${latency.inMilliseconds}ms)';
}