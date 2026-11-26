/// Llama.cpp 本地翻译引擎（MT）
///
/// 基于 `llama_cpp_dart 0.2.2` 的 [LlamaParent] + 独立 isolate 子进程，
/// 加载 Hy-MT1.5-1.8B-GGUF 做端侧离线翻译。
///
/// ## 设计要点
/// 1. **推理在独立 Isolate**：`LlamaParent` 内部通过 `typed_isolate`
///    把 llama.cpp 调用放到 child isolate，主线程只收发字符串。
/// 2. **流式输出**：`parent.stream` 每吐一个 token 就回调 [MTChunk]，
///    上层 `TranslationService` 做 100ms 防抖后再推悬浮窗。
/// 3. **失败自动降级**：任何一步失败（模型缺失 / 原生库缺失 / 加载超时）
///    都抛异常，由 `EngineManager.switchMTEngine()` 捕获，
///    上层再切回 `MockMT`，UI 红字提示，不崩溃。
///
/// ## ⚠️ 已知阻塞（Android 原生库缺失）
///
/// `llama_cpp_dart 0.2.2` 的 `pubspec.yaml` **没有 `flutter: plugin:` 段**，
/// 包内也不含任何 Android `.so`（只有 OpenCL 的 `libOpenCL.so`）。
/// 因此它的 `android/build.gradle`（依赖 `src/llama.cpp` 子模块 + CMake）
/// **不会**进入 Flutter 的 Gradle 构建图，产物里没有 `libmtmd.so`。
///
/// 后果：`Llama.libraryPath = "libmtmd.so"` →
/// `DynamicLibrary.open("libmtmd.so")` 在真机抛
/// `Invalid argument(s): Failed to load dynamic library`。
///
/// 本引擎因此会在 `initialize()` 阶段失败并降级回 `MockMT`。
/// 要真正跑通，需要满足以下**任一**条件：
/// - 上游发布带 `flutter: plugin:` 段 + 预编译 `.so` 的版本；
/// - 或本项目自行用 NDK 编出 `libmtmd.so` 并放进
///   `android/app/src/main/jniLibs/<abi>/`（需要 llama.cpp 源码 + CMake，
///   属于 CI 侧改动，见 HANDOVER 第 5 节）。
library live_translate.core.engine.llama_mt;

import 'dart:async';
import 'dart:developer';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:live_translate/core/model/model_storage.dart';

import 'mt_engine.dart';

/// Llama.cpp 本地翻译引擎
class LlamaMTEngine implements MTEngine {
  /// 引擎稳定标识（持久化 / UI 选项用）
  static const String kEngineId = 'llama_mt';

  @override
  String get engineId => kEngineId;

  @override
  String get displayName => 'Hy-MT1.5 本地翻译';

  @override
  bool isInitialized = false;

  @override
  bool isRunning = false;

  @override
  String sourceLanguage = 'en';

  @override
  String targetLanguage = 'ja';

  /// Hy-MT1.5 官方支持的语种（中英日韩等），这里列常用子集。
  @override
  final List<LanguagePair> supportedLanguagePairs = const [
    LanguagePair(source: 'en', target: 'ja', displayName: 'English → Japanese'),
    LanguagePair(source: 'en', target: 'zh', displayName: 'English → Chinese'),
    LanguagePair(source: 'en', target: 'ko', displayName: 'English → Korean'),
    LanguagePair(source: 'ja', target: 'en', displayName: 'Japanese → English'),
    LanguagePair(source: 'ja', target: 'zh', displayName: 'Japanese → Chinese'),
    LanguagePair(source: 'zh', target: 'en', displayName: 'Chinese → English'),
    LanguagePair(source: 'zh', target: 'ja', displayName: 'Chinese → Japanese'),
    LanguagePair(source: 'zh', target: 'ko', displayName: 'Chinese → Korean'),
    LanguagePair(source: 'ko', target: 'en', displayName: 'Korean → English'),
    LanguagePair(source: 'ko', target: 'zh', displayName: 'Korean → Chinese'),
    LanguagePair(source: 'ko', target: 'ja', displayName: 'Korean → Japanese'),
  ];

  /// 语言代码 → 官方 prompt 里的自然语言名
  ///
  /// Hy-MT1.5 的指令模板要写全称（`Japanese` 而非 `ja`），
  /// 写代码会让模型输出不稳定。
  static const Map<String, String> _languageNames = {
    'en': 'English',
    'zh': 'Chinese',
    'ja': 'Japanese',
    'ko': 'Korean',
    'ru': 'Russian',
    'th': 'Thai',
    'vi': 'Vietnamese',
    'ar': 'Arabic',
    'id': 'Indonesian',
  };

  // ---------------------------------------------------------------------------
  // 运行期状态
  // ---------------------------------------------------------------------------

  LlamaParent? _parent;

  /// 模型权重绝对路径（initialize 时解析）
  String? _modelPath;

  /// 当前正在进行的 promptId（用于过滤 stream 上的其他消息）
  String? _activePromptId;

  /// 流式累加缓冲
  final StringBuffer _buffer = StringBuffer();

  /// 最近一次错误说明（UI 可展示）
  String? _lastError;

  /// 模型是否真的加载成功
  bool _modelReady = false;

  /// 取消标记（stop / 新请求打断旧请求）
  bool _cancelled = false;

  // 获取器
  bool get isModelReady => _modelReady;

  String? get lastError => _lastError;

  String? get modelPath => _modelPath;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 加载权重并初始化 llama.cpp
  ///
  /// 抛异常表示无法使用真实引擎，由调用方降级回 Mock。
  @override
  Future<void> initialize({
    String? modelPath,
    String sourceLang = 'en',
    String targetLang = 'ja',
    Map<String, dynamic> config = const {},
  }) async {
    sourceLanguage = sourceLang;
    targetLanguage = targetLang;

    // 1) 解析权重路径（允许 config 覆盖，便于测试 / 指定其他 GGUF）
    _modelPath = (config['modelPath'] as String?) ??
        (modelPath != null && modelPath.trim().isNotEmpty
            ? modelPath.trim()
            : await ModelStorage.instance.resolveMtModelPath());

    if (_modelPath == null || _modelPath!.isEmpty) {
      _lastError = '未检测到翻译模型（*.gguf）';
      throw StateError(_lastError!);
    }

    // 2) 上下文参数：手机上必须保守，否则 1.8B 模型直接 OOM
    //
    // - nCtx 2048：一句字幕远用不到 4k，2048 足够且省内存
    // - nBatch / nUbatch 128：prompt 很短，batch 开大只是白占内存
    // - nThreads 4：留一半核给 UI / VAD / ASR，避免抢满卡顿
    // - flashAttention：手机上救内存的关键开关
    final contextParams = ContextParams()
      ..nCtx = (config['nCtx'] as num?)?.toInt() ?? 2048
      ..nBatch = 128
      ..nUbatch = 128
      ..nThreads = (config['nThreads'] as num?)?.toInt() ?? 4
      ..nThreadsBatch = (config['nThreads'] as num?)?.toInt() ?? 4
      // 单次最多生成多少 token（一句字幕 256 足够，超长会拖慢出字）
      ..nPredict = (config['nPredict'] as num?)?.toInt() ?? 256
      ..flashAttention = LlamaFlashAttnType.enabled;

    // 3) 采样参数：翻译任务要「稳」，温度必须低
    //
    // 翻译不是创作，高温会让同一句话每次译得不一样，
    // 甚至凭空添加原文没有的内容。
    final samplerParams = SamplerParams()
      ..temp = (config['temperature'] as num?)?.toDouble() ?? 0.2
      ..topK = 20
      ..topP = 0.8
      ..penaltyRepeat = 1.05;

    final loadCommand = LlamaLoad(
      path: _modelPath!,
      modelParams: ModelParams(),
      contextParams: contextParams,
      samplingParams: samplerParams,
      verbose: false,
    );

    try {
      _parent = LlamaParent(loadCommand);
      // 30s 冷加载兜底（1.8B Q4 在低端机上可能更慢，
      // 但无限等会让 UI 永远转圈）
      await _parent!.init().timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw TimeoutException('翻译模型加载超时（60s）'),
          );
      _modelReady = true;
      isInitialized = true;
      log(
        '[LlamaMT] 模型已加载: $_modelPath (nCtx=${contextParams.nCtx}, '
        'threads=${contextParams.nThreads})',
        name: 'LlamaMT',
      );
    } catch (e, s) {
      _lastError = '翻译模型加载失败: $e';
      log('[LlamaMT] 初始化失败: $e\n$s', name: 'LlamaMT');
      _modelReady = false;
      isInitialized = false;
      // 失败时立刻释放，避免半初始化状态占着内存
      await _parent?.dispose().catchError((_) {});
      _parent = null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 翻译
  // ---------------------------------------------------------------------------

  /// 按 Hy-MT1.5 官方模板拼 prompt
  ///
  /// 官方格式（见 HF 模型卡）：
  /// ```
  /// <|startoftext|>Translate the following segment into {target},
  /// without additional explanation.
  ///
  /// {source}<|endoftext|>
  /// ```
  String _buildPrompt(String text, String targetLang) {
    final targetName = _languageNames[targetLang] ?? targetLang;
    return '<|startoftext|>Translate the following segment into '
        '$targetName, without additional explanation.\n\n'
        '$text<|endoftext|>';
  }

  /// 流式翻译
  ///
  /// - [onChunk] 每收到一段增量文本回调一次（`isFinal=false`）
  /// - [onComplete] 全部结束后回调，带完整 `MTResult`
  /// - [onError] 任何失败回调，并自动降级（不抛给上层）
  @override
  Future<void> translateStream({
    required String text,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    final parent = _parent;
    if (parent == null || !_modelReady) {
      onError(StateError('LlamaMT 未就绪'), StackTrace.current);
      return;
    }
    if (text.trim().isEmpty) {
      onComplete(
        MTResult(
          sourceText: text,
          translatedText: '',
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          latency: Duration.zero,
        ),
      );
      return;
    }

    isRunning = true;
    _cancelled = false;
    _buffer.clear();
    final startTime = DateTime.now();

    // 订阅必须早于 sendPrompt，否则会漏掉最开始几个 token
    final textSub = parent.stream.listen((chunk) {
      if (_cancelled) return;
      _buffer.write(chunk);
      onChunk(
        MTChunk(
          text: _buffer.toString(),
          isFinal: false,
          chunkIndex: _buffer.length,
        ),
      );
    });

    final done = Completer<void>();

    final completionSub = parent.completions.listen((event) {
      // promptId 对不上说明是上一次请求的残留，忽略
      if (_activePromptId != null && event.promptId != _activePromptId) return;
      if (!done.isCompleted) {
        if (event.success) {
          done.complete();
        } else {
          done.completeError(
            StateError(event.errorDetails ?? '翻译生成失败'),
          );
        }
      }
    });

    try {
      _activePromptId = await parent.sendPrompt(_buildPrompt(text, targetLanguage));
      await done.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('翻译超时（30s）'),
      );

      final translated = _buffer.toString().trim();
      final latency = DateTime.now().difference(startTime);
      onComplete(
        MTResult(
          sourceText: text,
          translatedText: translated,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          latency: latency,
        ),
      );
      log(
        '[LlamaMT] "$text" -> "$translated" (${latency.inMilliseconds}ms)',
        name: 'LlamaMT',
      );
    } catch (e, s) {
      _lastError = '翻译失败: $e';
      log('[LlamaMT] 翻译失败: $e\n$s', name: 'LlamaMT');
      onError(e, s);
    } finally {
      _activePromptId = null;
      isRunning = false;
      await textSub.cancel();
      await completionSub.cancel();
    }
  }

  /// 一次性翻译（内部复用流式实现）
  @override
  Future<MTResult> translate(String text) async {
    final completer = Completer<MTResult>();
    await translateStream(
      text: text,
      onChunk: (_) {},
      onComplete: (result) {
        if (!completer.isCompleted) completer.complete(result);
      },
      onError: (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return completer.future;
  }

  /// 切换语言对
  ///
  /// Hy-MT1.5 是「指令式」翻译模型，语种写在 prompt 里，
  /// 不需要重新加载权重，只改字段即可。
  @override
  Future<void> switchLanguagePair(
    String sourceLang,
    String targetLang,
  ) async {
    final pair = supportedLanguagePairs.firstWhere(
      (p) => p.source == sourceLang && p.target == targetLang,
      orElse: () => throw ArgumentError(
        '不支持的语言对: $sourceLang -> $targetLang',
      ),
    );
    sourceLanguage = pair.source;
    targetLanguage = pair.target;
    log(
      '[LlamaMT] 语言对切换为 $sourceLanguage -> $targetLanguage',
      name: 'LlamaMT',
    );
  }

  /// 中断当前生成（新请求进来时先调，避免串台）
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _parent?.stop();
    } catch (_) {
      // 忽略
    }
  }

  @override
  Future<void> dispose() async {
    _cancelled = true;
    isRunning = false;
    isInitialized = false;
    _modelReady = false;
    _activePromptId = null;
    _buffer.clear();

    final parent = _parent;
    _parent = null;
    if (parent != null) {
      try {
        await parent.dispose().timeout(
              const Duration(seconds: 10),
              onTimeout: () {},
            );
      } catch (e) {
        log('[LlamaMT] 释放失败: $e', name: 'LlamaMT');
      }
    }
    log('[LlamaMT] 已释放', name: 'LlamaMT');
  }

  @override
  Map<String, dynamic> getStatus() {
    return {
      'engineId': engineId,
      'displayName': displayName,
      'isInitialized': isInitialized,
      'isRunning': isRunning,
      'modelReady': _modelReady,
      'sourceLanguage': sourceLanguage,
      'targetLanguage': targetLanguage,
      'modelPath': _modelPath,
      'error': _lastError,
    };
  }
}