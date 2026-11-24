/// ASR 引擎抽象接口
/// 负责将音频流转换为文本流
abstract interface class ASREngine {
  /// 引擎唯一标识符
  String get engineId;
  
  /// 引擎显示名称
  String get displayName;
  
  /// 是否已初始化
  bool get isInitialized;
  
  /// 是否正在运行
  bool get isRunning;
  
  /// 当前识别语言
  String get currentLanguage;
  
  /// 支持的语言列表
  List<String> get supportedLanguages;
  
  /// 初始化引擎
  /// [modelPath] 模型文件路径（可选，某些引擎可能不需要）
  /// [language] 识别语言
  /// [config] 额外配置参数
  Future<void> initialize({
    String? modelPath,
    String language = 'en',
    Map<String, dynamic> config = const {},
  });
  
  /// 启动识别
  /// 启动后通过 [onResult] 回调返回识别结果
  Future<void> start({
    required Function(ASRResult) onResult,
    required Function(Object error, StackTrace stack) onError,
  });
  
  /// 停止识别
  Future<void> stop();
  
  /// 推送音频数据（PCM 16kHz 16bit mono）
  /// [audioData] 音频字节数据
  Future<void> pushAudio(List<int> audioData);
  
  /// 切换语言
  Future<void> switchLanguage(String language);
  
  /// 释放资源
  Future<void> dispose();
  
  /// 获取引擎状态信息
  Map<String, dynamic> getStatus();
}

/// ASR 识别结果
class ASRResult {
  final String text;
  final bool isFinal;
  final double confidence;
  final Duration timestamp;
  final String language;
  
  const ASRResult({
    required this.text,
    required this.isFinal,
    this.confidence = 1.0,
    required this.timestamp,
    this.language = 'en',
  });
  
  @override
  String toString() => 'ASRResult(text: $text, isFinal: $isFinal, confidence: $confidence)';
}