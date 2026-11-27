/// Llama.cpp 本地翻译引擎（MT）
///
/// 基于 `llama_cpp_dart 0.9.0-dev.12` 的 [LlamaEngine]：
/// `LlamaEngine.spawn()` 起一个 worker isolate，模型权重与 KV cache 都活在
/// 那个 isolate 里，主 isolate 只收发事件流。
///
/// ## 设计要点
///
/// 1. **推理在独立 Isolate**：`LlamaEngine` 内部 `Isolate.spawn(runEngineWorker)`，
///    FFI 绑定的 `LlamaLibrary.load()` 也在 worker 内调用（FFI 绑定是 per-isolate 的，
///    主 isolate 不持有任何 native 句柄）。
/// 2. **流式输出**：`session.generate()` 返回 `Stream<GenerationEvent>`，
///    每来一个 [TokenEvent] 就把增量文本回调给上层 [MTChunk]，
///    上层 `TranslationService` 做 100ms 防抖后再推悬浮窗。
/// 3. **失败自动降级**：任何一步失败（模型缺失 / 原生库缺失 / 加载超时）
///    都抛异常，由 `EngineManager.switchMTEngine()` 捕获后降级回 `MockMT`，
///    UI 用红字提示原因，不崩溃。
///
/// ## 原生库是怎么进 APK 的（曾经的 P0 阻塞，现已解决）
///
/// 旧版本 `0.2.2` 的 pubspec **没有 `flutter: plugin:` 段**，包内也不含任何
/// Android `.so`，导致它的 `android/build.gradle` 根本不进 Flutter 的 Gradle
/// 构建图，产物里没有 `libmtmd.so`，真机 `DynamicLibrary.open("libmtmd.so")`
/// 必失败。
///
/// `0.9.0-dev.12` 改走 **native assets 构建钩子**（`hook/build.dart`），并自带
/// `native/android/llama-cpp-dart.aar`，内含
/// `jni/arm64-v8a/{libllama,libmtmd,libggml,libggml-base,libggml-cpu}.so`。
/// Flutter 的 `nativeAssets` 特性在 stable 默认开启，`flutter assemble` 会把它们
/// 解到 `build/.../native_assets/jniLibs/lib/<abi>/`，
/// 再由 `CopyFlutterJniLibsTask` 复制进 APK 的 jniLibs —— 不需要改
/// `android/app/build.gradle.kts`，也不需要 NDK/CMake。
///
/// ### ⚠️ ABI 限制（重要）
///
/// 官方那个 AAR **只带 arm64-v8a**。因此：
/// - `arm64-v8a` 的 APK 里有完整的 llama.cpp，真实翻译可用；
/// - `armeabi-v7a` / `x86_64` 的 APK 里**没有**这些 `.so`，
///   本引擎会在 `spawn()` 阶段失败并降级 `MockMT`（不崩溃，`engineNote` 会说明）。
///
/// 这是上游产物限制，不是本项目配置问题。若要补齐其他 ABI，
/// 需在 CI 里自建 AAR 并放进 `jniLibs/`，属于后续优化项。
library live_translate.core.engine.llama_mt;

import 'dart:async';
import 'dart:developer';
import 'dart:io' show Platform;

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:live_translate/core/i18n/language_registry.dart';
import 'package:live_translate/core/model/model_catalog.dart'
    show MtPromptStyle;
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

  /// 支持的语言对
  ///
  /// v0.7.0 起从 [LanguageRegistry.mtPairs] 派生（12 种语言 × 11 = 132 个方向）。
  ///
  /// 旧实现硬编码了 11 个方向，`en→ru`、`ja→fr` 这类完全合理的组合会直接
  /// 抛 `ArgumentError`——而 `switchLanguagePair` 的调用方
  /// `TranslationService.setMTLanguagePair` 没有 try/catch，
  /// 结果就是**未捕获异步异常**。Hy-MT1.5 / Qwen2.5 都是指令式多语模型，
  /// 语种只写在 prompt 里，不存在「只支持这 11 个方向」的物理限制。
  @override
  final List<LanguagePair> supportedLanguagePairs = LanguageRegistry.mtPairs;

  // 语言代码 → prompt 里的自然语言名，统一走 [LanguageRegistry.mtPromptName]。
  //
  // Hy-MT1.5 的指令模板要写全称（`Japanese` 而非 `ja`），写代码会让模型
  // 输出不稳定。v0.7.0 起不再本地维护一份只有 9 种语言、缺 `fr/de/es`
  // 的映射表（缺的语言会原样把语言代码拼进 prompt）。

  // ---------------------------------------------------------------------------
  // 运行期状态
  // ---------------------------------------------------------------------------

  /// worker isolate 句柄（内部持有 native 模型与 context）
  LlamaEngine? _engine;

  /// 复用的会话（持有 token 历史与 KV 游标）
  ///
  /// 每句翻译前会 `clear()`，避免上下文无限增长导致 KV cache 打满。
  EngineSession? _session;

  /// 模型权重绝对路径（initialize 时解析）
  String? _modelPath;

  /// 当前正在消费的事件流订阅（用于 cancel）
  StreamSubscription<GenerationEvent>? _activeSub;

  /// 流式累加缓冲
  final StringBuffer _buffer = StringBuffer();

  /// 最近一次错误说明（UI 可展示）
  String? _lastError;

  /// 模型是否真的加载成功
  bool _modelReady = false;

  /// 取消标记（stop / 新请求打断旧请求）
  bool _cancelled = false;

  /// 单次生成最多产出多少 token（可在 config 覆盖）
  int _maxTokens = 256;

  /// 采样参数（每次 translate 复用，保持温度稳定）
  SamplerParams _sampler = const SamplerParams(
    temperature: 0.2,
    topK: 20,
    topP: 0.8,
    repeatPenalty: 1.05,
  );

  /// 提示词模板（由 config 决定，默认混元模板）
  ///
  /// 不同模型对指令格式极度敏感：用错模板不会报错，
  /// 只会「原样输出」或吐出一串乱码，属于最难排查的一类问题。
  MtPromptStyle _promptStyle = MtPromptStyle.hyMt;

  /// 当前使用的提示词模板（诊断用）
  MtPromptStyle get promptStyle => _promptStyle;

  // 获取器
  bool get isModelReady => _modelReady;

  String? get lastError => _lastError;

  String? get modelPath => _modelPath;

  /// 当前平台是否可能有 llama.cpp 原生库
  ///
  /// 上游发布的 AAR 只含 Android arm64-v8a；桌面 / iOS 需要另配动态库。
  /// 这个判断只用于 UI 上的诊断信息，真正的失败由 `spawn()` 抛出并被上层降级。
  static bool get isNativeLibraryExpected => Platform.isAndroid;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 加载权重并起 worker isolate
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

    // 0) 提示词模板：不同模型必须用各自的指令格式
    final styleName = config['promptStyle'] as String?;
    _promptStyle = switch (styleName) {
      'chatMl' => MtPromptStyle.chatMl,
      'hyMt' => MtPromptStyle.hyMt,
      _ => _promptStyle,
    };

    // 1) 解析权重路径（允许 config 覆盖，便于测试 / 指定其他 GGUF）
    _modelPath =
        (config['modelPath'] as String?) ??
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
    // - flashAttn auto：交给 llama.cpp 决定。不要硬写 on ——
    //   `FlashAttention.on` 在后端不支持时会直接报错。
    final contextParams = ContextParams(
      nCtx: (config['nCtx'] as num?)?.toInt() ?? 2048,
      nBatch: 128,
      nUbatch: 128,
      nThreads: (config['nThreads'] as num?)?.toInt() ?? 4,
      nThreadsBatch: (config['nThreads'] as num?)?.toInt() ?? 4,
      flashAttn: FlashAttention.auto,
    );

    // 3) 采样参数：翻译任务要「稳」，温度必须低
    //
    // 翻译不是创作，高温会让同一句话每次译得不一样，
    // 甚至凭空添加原文没有的内容。
    _maxTokens =
        (config['maxTokens'] as num?)?.toInt() ??
        // 兼容旧配置键（0.2.x 时代叫 nPredict，在 ContextParams 上）
        (config['nPredict'] as num?)?.toInt() ??
        256;

    final temperature = (config['temperature'] as num?)?.toDouble() ?? 0.2;
    _sampler = SamplerParams(
      temperature: temperature,
      topK: 20,
      topP: 0.8,
      repeatPenalty: 1.05,
    );

    // 4) 起 worker isolate 并加载权重
    //
    // `LlamaEngine.spawn` 不传 libraryPath 时用 `LlamaLibrary.defaultFileName()`，
    // Android 上是裸名 `libllama.so` —— 走 linker 的 basename 解析，
    // 正好命中 APK 里的 jniLibs，无需绝对路径。
    // libmtmd 也会按 basename 打开（可选，失败不影响纯文本生成）。
    final modelParams = ModelParams(
      path: _modelPath!,
      // Android 侧只打了 ggml-cpu，没有 GPU/NPU 后端，必须是 0
      gpuLayers: 0,
    );

    try {
      _engine =
          await LlamaEngine.spawn(
            modelParams: modelParams,
            contextParams: contextParams,
          ).timeout(
            // 1.8B Q4 在低端机上冷加载可能很慢，但无限等会让 UI 永远转圈
            const Duration(seconds: 90),
            onTimeout: () => throw TimeoutException('翻译模型加载超时（90s）'),
          );

      _session = await _engine!.createSession();

      _modelReady = true;
      isInitialized = true;
      log(
        '[LlamaMT] 模型已加载: $_modelPath '
        '(nCtx=${contextParams.nCtx}, threads=${contextParams.nThreads}, '
        'maxTokens=$_maxTokens, temp=$temperature)',
        name: 'LlamaMT',
      );
    } catch (e, s) {
      _lastError = _describeLoadFailure(e);
      log('[LlamaMT] 初始化失败: $e\n$s', name: 'LlamaMT');
      _modelReady = false;
      isInitialized = false;
      // 失败时立刻释放，避免半初始化状态占着内存
      await _teardownQuietly();
      // 统一抛 StateError，让上层 / 测试拿到可读原因
      throw StateError(_lastError!);
    }
  }

  /// 把底层异常翻译成用户能看懂的一句话
  ///
  /// 最常见的是「原生库不在包里」：`LlamaLibraryException: failed to open
  /// libllama.so`，这在不同 ABI 的 APK 上必然出现（上游 AAR 只带 arm64）。
  String _describeLoadFailure(Object e) {
    final text = e.toString();
    final looksLikeMissingNative =
        text.contains('libllama.so') ||
        text.contains('libmtmd.so') ||
        text.contains('failed to open') ||
        text.contains('DynamicLibrary');

    if (looksLikeMissingNative) {
      return '翻译原生库加载失败（libllama.so / libmtmd.so）。'
          '当前 APK 架构可能不含 llama.cpp（官方产物仅 arm64-v8a）：$e';
    }
    return '翻译模型加载失败: $e';
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
  ///
  /// v0.6.0 起支持多种模板：Qwen2.5 等 instruct 模型用 ChatML，
  /// 混元系列用上面的专用模板。用错模板不会报错，只会「输出原文/乱码」，
  /// 属于最难排查的一类问题，所以模板由 [MtModelSpec] 显式指定。
  String _buildPrompt(String text, String targetLang) {
    // 未知语言代码原样返回（而非抛异常）：宁可译得差一点，
    // 也不能让整条翻译链路因为一个语种代码断掉。
    final targetName = LanguageRegistry.mtPromptName(targetLang);
    switch (_promptStyle) {
      case MtPromptStyle.chatMl:
        return '<|im_start|>system\n'
            'You are a professional translator. Translate the user\'s text '
            'into $targetName. Output only the translation, '
            'without any explanation or extra text.<|im_end|>\n'
            '<|im_start|>user\n'
            '$text<|im_end|>\n'
            '<|im_start|>assistant\n';
      case MtPromptStyle.hyMt:
        return '<|startoftext|>Translate the following segment into '
            '$targetName, without additional explanation.\n\n'
            '$text<|endoftext|>';
    }
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
    final session = _session;
    if (session == null || !_modelReady) {
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

    final done = Completer<void>();
    StreamSubscription<GenerationEvent>? sub;

    try {
      // 每句都从干净上下文开始：不清的话 token 历史 + KV 会一路累加，
      // 几十句之后必然撞上 nCtx 上限。
      await session.clear();

      final rawStream = session.generate(
        prompt: _buildPrompt(text, targetLanguage),
        // 模板里自带 <|startoftext|>，不要再让 tokenizer 加一遍
        addSpecial: false,
        sampler: _sampler,
        maxTokens: _maxTokens,
      );

      // 单次事件间隔兜底：低端机上 prefill 可能要几秒，
      // 但 45s 都没有新 token 基本就是卡死，必须切断避免 UI 永久转圈。
      final guarded = rawStream.timeout(
        const Duration(seconds: 45),
        onTimeout: (sink) {
          sink.addError(TimeoutException('翻译超时（45s 无新 token）'));
          sink.close();
        },
      );

      sub = guarded.listen(
        (event) {
          if (_cancelled) return;
          switch (event) {
            case TokenEvent():
              _buffer.write(event.text);
              if (event.text.isEmpty) return;
              onChunk(
                MTChunk(
                  text: _buffer.toString(),
                  isFinal: false,
                  chunkIndex: _buffer.length,
                ),
              );
            case ShiftEvent():
              // KV cache 被自动平移了；这里不镜像 token 列表，
              // 因为每句都 clear()，不会累积到需要 shift 的长度。
              log('[LlamaMT] context shifted', name: 'LlamaMT');
            case DoneEvent():
              if (!done.isCompleted) done.complete();
          }
        },
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      _activeSub = sub;

      await done.future;

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
      _activeSub = null;
      isRunning = false;
      try {
        await sub?.cancel();
      } catch (_) {
        // 取消本身失败不算错误
      }
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
  Future<void> switchLanguagePair(String sourceLang, String targetLang) async {
    final pair = supportedLanguagePairs.firstWhere(
      (p) => p.source == sourceLang && p.target == targetLang,
      orElse: () => throw ArgumentError('不支持的语言对: $sourceLang -> $targetLang'),
    );
    sourceLanguage = pair.source;
    targetLanguage = pair.target;
    log('[LlamaMT] 语言对切换为 $sourceLanguage -> $targetLanguage', name: 'LlamaMT');
  }

  /// 中断当前生成（新请求进来时先调，避免串台）
  ///
  /// 取消订阅会向 worker 发 `CancelCommand`，worker 在下一个 decode
  /// 边界停下，不会继续白烧 CPU。
  Future<void> cancel() async {
    _cancelled = true;
    final sub = _activeSub;
    _activeSub = null;
    try {
      await sub?.cancel();
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
    _buffer.clear();
    await _teardownQuietly();
    log('[LlamaMT] 已释放', name: 'LlamaMT');
  }

  /// 释放顺序：先取消流 → 再关 session → 最后销毁 engine
  ///
  /// `LlamaEngine.dispose()` 会向 worker 发 ShutdownCommand 并在 worker 内
  /// 释放 model / context，所以必须在 session 之后。
  Future<void> _teardownQuietly() async {
    final sub = _activeSub;
    _activeSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}

    final session = _session;
    _session = null;
    if (session != null) {
      try {
        await session.dispose().timeout(const Duration(seconds: 10));
      } catch (e) {
        log('[LlamaMT] session 释放失败: $e', name: 'LlamaMT');
      }
    }

    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        await engine.dispose().timeout(const Duration(seconds: 20));
      } catch (e) {
        log('[LlamaMT] engine 释放失败: $e', name: 'LlamaMT');
      }
    }
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
      'promptStyle': _promptStyle.name,
      'nativeLibraryExpected': isNativeLibraryExpected,
    };
  }
}
