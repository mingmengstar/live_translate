/// Llama.cpp 本地翻译引擎（MT）—— **流式字幕专用**
///
/// 基于 `llama_cpp_dart 0.9.0-dev.12` 的 [LlamaEngine]：
/// `LlamaEngine.spawn()` 起一个 worker isolate，模型权重与 KV cache 都活在
/// 那个 isolate 里，主 isolate 只收发事件流。
///
/// ## v0.8.0 重写：从「整句翻译」改成「流式增量译」
///
/// ### 旧实现为什么不可用
///
/// 旧版只在 `isFinal` 时才调用 [translateStream]，等 ASR 吐出一整句再翻。
/// 对实时字幕来说这是根本性错误：
///
/// - 用户说完一整句之前，屏幕上一个字都没有 —— 不叫「实时」；
/// - 换用 StreamRevise 模型后问题更严重：这类模型**必须**在每次
///   ASR 局部更新时被调用，并带上「上一版译文」。只调用一次等于
///   丢掉了它全部的核心能力（前缀保留 + 修订），于是只会输出原文或乱码。
///
/// ### 现在的协议
///
/// 调用方（`TranslationService`）每拿到一次 ASR 文本变化就调用
/// [translateStream]，并通过 [revise] 传入：
///
/// - [text]：本句**当前**的完整识别文本（不是增量片段）；
/// - [previousTranslation]：本句上一版译文（首译时为空）；
/// - [recentSources]：前文若干句的原文（提供上下文，最多 5 句）；
/// - [isFinal]：本句 ASR 是否已定稿。
///
/// 引擎据此渲染模型专属的 StreamRevise 提示词：
///
/// - Hy-MT3 用 `【背景信息】/【待翻译文本】` + 中文语言名 + `状态：进行中|本句结束`
/// - Hy-MT2 用 `[Background Information]/[Source Text]` + 英文语言名
///
/// ### 关键采样参数（来自模型卡，**改动需谨慎**）
///
/// | 参数 | 值 | 原因 |
/// |---|---|---|
/// | `temperature` | **0** | 必须贪心。采样会让相邻两次几乎相同的 ASR 更新产生随机改词，字幕抖动 |
/// | `topK` | **1** | 同上，配合 temperature=0 才是严格贪心 |
/// | `repeatPenalty` | **1.0** | 开惩罚会让模型不敢沿用上一版译文的前缀，反而破坏稳定性 |
///
/// ## 原生库是怎么进 APK 的（曾经的 P0 阻塞，现已解决）
///
/// `0.9.0-dev.12` 走 **native assets 构建钩子**（`hook/build.dart`），自带
/// `native/android/llama-cpp-dart.aar`，内含
/// `jni/arm64-v8a/{libllama,libmtmd,libggml,libggml-base,libggml-cpu}.so`。
///
/// ### ⚠️ ABI 限制（重要）
///
/// 官方那个 AAR **只带 arm64-v8a**。因此：
/// - `arm64-v8a` 的 APK 里有完整的 llama.cpp，真实翻译可用；
/// - `armeabi-v7a` / `x86_64` 的 APK 里**没有**这些 `.so`，
///   本引擎会在 `spawn()` 阶段失败（不崩溃，`engineNote` 会说明）。
library live_translate.core.engine.llama_mt;

import 'dart:async';
import 'dart:developer';
import 'dart:io' show Platform;

import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:live_translate/core/i18n/language_registry.dart';
import 'package:live_translate/core/model/model_catalog.dart'
    show ModelCatalog, MtModelVariant, MtPromptStyle;
import 'package:live_translate/core/model/model_storage.dart';

import 'mt_engine.dart';

/// 流式翻译请求（比 [MTEngine.translateStream] 多带「修订上下文」）
///
/// 单独定义而不是往接口里加参数，是为了不破坏 `MTEngine` 的通用契约
/// （Mock 引擎仍然只需要 text）。
class StreamTranslateRequest {
  const StreamTranslateRequest({
    required this.text,
    this.previousTranslation = '',
    this.previousSource = '',
    this.recentSources = const [],
    this.isFinal = false,
  });

  /// 本句**当前**完整识别文本（不是增量片段）
  final String text;

  /// 本句上一版译文；首译时为空串
  ///
  /// 这是 StreamRevise 模型的核心输入 —— 它靠比对这个值来决定
  /// 沿用哪段前缀、改写哪一段。传空等于放弃前缀保留能力。
  final String previousTranslation;

  /// 本句**上一版原文**（也就是上一轮 ASR 的识别文本）；首译时为空串
  ///
  /// ⚠️ 只有 **Hy-MT2** 的模板有 `Previous version of the current source:`
  /// 这个槽位。Hy-MT3 的官方模板**刻意不传上一版原文**（发布卡原文：
  /// 「模板刻意不传入 `上一版原文`，迫使模型直接将 `上一版译文` 与
  /// `【待翻译文本】` 对照，减少错误沿用」），所以 Hy-MT3 渲染时忽略该字段。
  ///
  /// 该字段**绝不能**拿 `previousTranslation` 顶替 —— 那等于告诉模型
  /// 「上一版原文就是这段译文」，前缀对照从输入层就是错的。没有就留空，
  /// 渲染时会整块省略。
  final String previousSource;

  /// 前文若干句的**原文**（最多 5 句），提供跨句上下文
  ///
  /// 只传原文而不传双语对照，是模型卡的建议：迫使模型直接对照
  /// 「上一版译文」与「待翻译文本」，减少错误沿用。
  final List<String> recentSources;

  /// 本句 ASR 是否已定稿
  ///
  /// - `false`（进行中）：只翻译已出现内容，不猜后文，不补句尾标点；
  /// - `true`（本句结束）：保留前缀并补齐结尾标点。
  final bool isFinal;

  bool get isEmpty => text.trim().isEmpty;
}

/// 本次翻译被 [LlamaMTEngine.cancel] 中断
///
/// **不是错误**：实时字幕的正常节奏就是「ASR 每 ~300ms 更新一次，
/// 每次都用更新的文本取消上一次推理」。所以它必须与真正的翻译失败区分开，
/// 否则用户会看到满屏「翻译错误」日志，而且半截结果可能被当成有效译文
/// 写进译文链，污染下一轮的 previousTranslation。
///
/// 上层（`TranslationService._translateCurrentSentence`）应当静默吞掉它。
class TranslationCancelledException implements Exception {
  const TranslationCancelledException();

  @override
  String toString() => '翻译已取消（被更新的一次识别结果打断）';
}

/// Llama.cpp 本地翻译引擎
class LlamaMTEngine implements MTEngine {
  /// 引擎稳定标识（持久化 / UI 选项用）
  static const String kEngineId = 'llama_mt';

  /// 上下文里保留的前文句数上限
  ///
  /// 模型卡建议「最多 5 句」：再多对译文质量的边际收益很小，
  /// 却会让每次 prefill 变长，直接拖慢实时性。
  static const int maxContextSentences = 5;

  @override
  String get engineId => kEngineId;

  @override
  String get displayName => 'Hy-MT 流式本地翻译';

  @override
  bool isInitialized = false;

  @override
  bool isRunning = false;

  @override
  String sourceLanguage = 'en';

  @override
  String targetLanguage = 'ja';

  /// 支持的语言对（中日英 6 个方向）
  @override
  final List<LanguagePair> supportedLanguagePairs = LanguageRegistry.mtPairs;

  // ---------------------------------------------------------------------------
  // 运行期状态
  // ---------------------------------------------------------------------------

  /// worker isolate 句柄（内部持有 native 模型与 context）
  LlamaEngine? _engine;

  /// 复用的会话（持有 token 历史与 KV 游标）
  EngineSession? _session;

  /// 模型权重绝对路径（initialize 时解析）
  String? _modelPath;

  /// 当前正在消费的事件流订阅（用于 cancel）
  StreamSubscription<GenerationEvent>? _activeSub;

  /// 当前这一次生成的「完成信号」
  ///
  /// 为什么要有它：`sub.cancel()` **不会**触发 `onDone`，所以取消之后
  /// `await done.future` 会永久挂住 —— 表现是 `isRunning` 卡在 true、
  /// `_activeSub` 不清空，下一条请求还会撞上仍在 worker 里跑的上一次推理
  /// （`session.clear()` 与 KV cache 冲突）。
  ///
  /// 所以 `cancel()` 必须主动把它 complete 掉，让 `translateStreamRevise`
  /// 的 `finally` 有机会跑完。
  Completer<void>? _activeDone;

  /// 当前这一次生成的「整体结束」信号（含 finally 收尾）
  ///
  /// 新请求进来时要先 `await` 它，确保上一次真正收尾（订阅已取消、
  /// `session` 已空闲），再执行 `session.clear()`。
  Future<void>? _inflight;

  /// 流式累加缓冲
  final StringBuffer _buffer = StringBuffer();

  /// 最近一次错误说明（UI 可展示）
  String? _lastError;

  /// 模型是否真的加载成功
  bool _modelReady = false;

  /// 取消标记（stop / 新请求打断旧请求）
  bool _cancelled = false;

  /// 单次生成最多产出多少 token（可在 config 覆盖）
  ///
  /// 160 与模型卡示例一致：一句字幕远用不到更多，设小一点能让
  /// 模型更早停下，减少无效 decode 的延迟。
  int _maxTokens = 160;

  /// 采样参数：**严格贪心**
  ///
  /// 这三个值直接来自模型卡，不要「顺手优化」：
  /// - `temperature: 0`：采样会让相邻两次近似相同的 ASR 更新产生随机改词；
  /// - `topK: 1`：配合 temperature=0 才是严格贪心；
  /// - `repeatPenalty: 1.0`：**不能开惩罚**。StreamRevise 的正常行为就是
  ///   大量沿用上一版译文（重复），开惩罚会逼模型换词，字幕反而乱跳。
  SamplerParams _sampler = const SamplerParams(
    temperature: 0,
    topK: 1,
    topP: 1.0,
    repeatPenalty: 1.0,
  );

  /// 提示词模板（由 config / 模型规格决定）
  MtPromptStyle _promptStyle = MtPromptStyle.hyMt3Stream;

  /// 当前使用的提示词模板（诊断用）
  MtPromptStyle get promptStyle => _promptStyle;

  /// 权重与提示词模板不匹配的说明（null 表示一致）
  ///
  /// 两个 StreamRevise 模型的模板互不兼容：用 A 的模板喂 B 的权重
  /// 不报错，只会输出原文 / 乱码 / 无限重复。一旦检测到不一致就在这里留话，
  /// 让上层能直接告诉用户「你选的模型没下载」。
  String? _modelVariantMismatch;

  /// 权重与提示词模板不匹配的说明（不一致时非 null）
  String? get modelVariantMismatch => _modelVariantMismatch;

  /// 由**当前模板风格**反推模型变体
  ///
  /// 模板风格才是真正喂给模型的东西，所以以它为准反查变体，
  /// 再取该变体的确切文件名。这样即使调用方只传了 `promptStyle`，
  /// 也能保证「加载的权重」与「使用的模板」属于同一个模型。
  MtModelVariant get variantFromStyle => switch (_promptStyle) {
        MtPromptStyle.hyMt2Stream => MtModelVariant.hyMt2StreamRevise,
        MtPromptStyle.hyMt3Stream => MtModelVariant.hyMt3StreamRevise,
      };

  /// 仅测试注入用：直接指定模板风格
  ///
  /// 真实路径由 [initialize] 的 `config['promptStyle']` 设置（值来自
  /// `ModelCatalog.mtSpec(variant).promptStyle`）。测试无法走 [initialize]
  /// （它会真的去加载 1GB 权重），所以留这个入口来验证「两套模板不能混用」。
  void debugSetPromptStyle(MtPromptStyle style) {
    _promptStyle = style;
  }

  // 获取器
  bool get isModelReady => _modelReady;

  String? get lastError => _lastError;

  String? get modelPath => _modelPath;

  /// 当前平台是否可能有 llama.cpp 原生库
  static bool get isNativeLibraryExpected => Platform.isAndroid;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 加载权重并起 worker isolate
  @override
  Future<void> initialize({
    String? modelPath,
    String sourceLang = 'en',
    String targetLang = 'ja',
    Map<String, dynamic> config = const {},
  }) async {
    sourceLanguage = sourceLang;
    targetLanguage = targetLang;

    // 0) 提示词模板：两个 StreamRevise 模型格式不兼容，必须显式指定
    final styleName = config['promptStyle'] as String?;
    _promptStyle = switch (styleName) {
      'hyMt2Stream' => MtPromptStyle.hyMt2Stream,
      'hyMt3Stream' => MtPromptStyle.hyMt3Stream,
      _ => _promptStyle,
    };

    // 1) 解析权重路径
    //
    // ## 必须按「所选变体」解析（P0，译文乱码/重复的根因之一）
    //
    // `resolveMtModelPath()` 旧实现返回目录里**第一个** `.gguf`。
    // 当目录同时存在 Hy-MT2 与 Hy-MT3 两个权重时，用户选的变体
    // （决定 `_promptStyle`）和实际加载的权重可能**不是同一个模型**，
    // 于是用 A 的模板喂 B 的权重 —— 不报错，只输出原文/乱码/无限重复。
    //
    // 所以这里把「该变体对应的确切文件名」传给存储层，
    // 并在加载后校验一次，把不匹配状态明确记录下来。
    final expectedMtFileName =
        (config['mtFileName'] as String?) ??
            ModelCatalog.mtFileFor(variantFromStyle).fileName;

    _modelPath =
        (config['modelPath'] as String?) ??
        (modelPath != null && modelPath.trim().isNotEmpty
            ? modelPath.trim()
            : await ModelStorage.instance.resolveMtModelPath(
                expectedFileName: expectedMtFileName,
              ));

    if (_modelPath == null || _modelPath!.isEmpty) {
      _lastError = '未检测到翻译模型（*.gguf）';
      throw StateError(_lastError!);
    }

    // 记录实际加载的文件名，并和所选变体比对。
    // 不一致说明「用户选的模型没下载、只能退回另一个」，模板会被混用，
    // 必须让上层能在 UI 上看见，而不是让用户对着乱码猜。
    final loadedFileName = _modelPath!.split(Platform.pathSeparator).last;
    if (loadedFileName != expectedMtFileName) {
      _modelVariantMismatch =
          '所选模型（$expectedMtFileName）未下载，实际加载 $loadedFileName；'
          '两套提示词模板不兼容，译文可能异常';
      log(
        '[LlamaMT] 权重与提示词模板可能不匹配: '
        '期望=$expectedMtFileName 实际=$loadedFileName',
        name: 'LlamaMT',
      );
    } else {
      _modelVariantMismatch = null;
    }

    // 2) 上下文参数
    //
    // - nCtx 2048：StreamRevise 的 prompt 比整句翻译长（含背景信息 +
    //   上一版译文），1024 容易不够用；2048 在 1.8B 上内存仍可控
    //   （模型卡实测权重 + KV ≈ 1.19 GiB）
    // - nBatch / nUbatch 128：prompt 不长，开大只是白占内存
    // - nThreads 4：留一半核给 UI / VAD / ASR，避免抢满卡顿
    // - flashAttn auto：交给 llama.cpp 决定，硬写 on 在后端不支持时会报错
    final contextParams = ContextParams(
      nCtx: (config['nCtx'] as num?)?.toInt() ?? 2048,
      nBatch: 128,
      nUbatch: 128,
      nThreads: (config['nThreads'] as num?)?.toInt() ?? 4,
      nThreadsBatch: (config['nThreads'] as num?)?.toInt() ?? 4,
      flashAttn: FlashAttention.auto,
    );

    _maxTokens = (config['maxTokens'] as num?)?.toInt() ?? 160;

    // 采样参数：允许测试覆盖，但默认必须是模型卡推荐值
    final temperature = (config['temperature'] as num?)?.toDouble() ?? 0;
    final topK = (config['topK'] as num?)?.toInt() ?? 1;
    _sampler = SamplerParams(
      temperature: temperature,
      topK: topK,
      topP: 1.0,
      repeatPenalty: (config['repeatPenalty'] as num?)?.toDouble() ?? 1.0,
    );

    // 3) 起 worker isolate 并加载权重
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
            const Duration(seconds: 90),
            onTimeout: () => throw TimeoutException('翻译模型加载超时（90s）'),
          );

      _session = await _engine!.createSession();

      _modelReady = true;
      isInitialized = true;
      log(
        '[LlamaMT] 模型已加载: $_modelPath '
        '(nCtx=${contextParams.nCtx}, threads=${contextParams.nThreads}, '
        'maxTokens=$_maxTokens, temp=$temperature, topK=$topK, '
        'style=${_promptStyle.name})',
        name: 'LlamaMT',
      );
    } catch (e, s) {
      _lastError = _describeLoadFailure(e);
      log('[LlamaMT] 初始化失败: $e\n$s', name: 'LlamaMT');
      _modelReady = false;
      isInitialized = false;
      await _teardownQuietly();
      throw StateError(_lastError!);
    }
  }

  /// 把底层异常翻译成用户能看懂的一句话
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
  // 提示词渲染
  // ---------------------------------------------------------------------------

  /// 按 Hy-MT3 StreamRevise 官方模板拼 prompt
  ///
  /// 模板来源：`febilly/Hy-MT3-1.8B-StreamRevise-GGUF` 的 README_CN.md。
  /// 结构刻意与官方一致：
  ///
  /// ```text
  /// 【背景信息】
  /// 这是实时语音字幕翻译：...
  ///
  /// 前文上下文：
  /// {RECENT_SOURCE_1}
  ///
  /// 上一版译文：
  /// {PREVIOUS_TRANSLATION}
  ///
  /// 状态：{STATE}
  ///
  /// 请结合背景信息将以下文本翻译为{TARGET_LANGUAGE}，...
  ///
  /// 【待翻译文本】
  /// {CURRENT_SOURCE}
  /// ```
  ///
  /// 要点：
  /// - `{STATE}` 必须是 `进行中` 或 `本句结束`（中文），写英文不生效；
  /// - 没有前文时**整块省略** `前文上下文：`，不要留空行占位；
  /// - 首译时**整块省略** `上一版译文：`；
  /// - 目标语言用**中文名**（`日语` 而不是 `Japanese`）。
  String _buildHyMt3Prompt(StreamTranslateRequest request, String targetName) {
    final buffer = StringBuffer()
      ..writeln('【背景信息】')
      ..writeln('这是实时语音字幕翻译：结合上下文与上一版译文，'
          '尽量沿用仍然正确的前缀；进行中可输出半句且不猜后文，'
          '本句结束时补全结尾。');

    if (request.recentSources.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('前文上下文：');
      for (final line in request.recentSources) {
        buffer.writeln(line);
      }
    }

    if (request.previousTranslation.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('上一版译文：')
        ..writeln(request.previousTranslation.trim());
    }

    buffer
      ..writeln()
      ..writeln('状态：${request.isFinal ? '本句结束' : '进行中'}')
      ..writeln()
      ..writeln('请结合背景信息将以下文本翻译为$targetName，'
          '注意只需要输出翻译后的结果，不要额外解释。')
      ..writeln()
      ..writeln('【待翻译文本】')
      ..write(request.text.trim());

    return buffer.toString();
  }

  /// 按 Hy-MT2 StreamRevise v4 官方模板拼 prompt
  ///
  /// 模板来源：`febilly/Hy-MT2-1.8B-StreamRevise-v4-GGUF` 的 README.md，
  /// 以及 `febilly/Hy-MT2-1.8B-StreamRevise-v4-LoRA` 的
  /// 「Copy-paste renderer」。本实现逐行对齐该 renderer。
  ///
  /// 与 Hy-MT3 的差异（**不能混用**）：
  ///
  /// - 结构标记是**英文方括号** `[Background Information]` / `[Source Text]`；
  /// - 目标语言用**英文全称**（`Japanese`）；
  /// - 首译走「整句锚点」短模板（模型保留 15% 原生整句样本）；
  /// - 后续更新走带 `Previous version of the current source` 的长模板。
  ///
  /// 官方 renderer 的块顺序与分隔规则（**改动前先对照原文**）：
  ///
  /// ```text
  /// [Background Information]
  /// {block1}
  ///
  /// {block2}
  ///
  /// {block3}
  /// ...
  ///
  /// Please translate the following text from {SOURCE} into {TARGET}, ...
  ///
  /// [Source Text]
  /// {CURRENT_SOURCE}
  /// ```
  ///
  /// - 每个 background 块**都是可选的**，块之间用**一个空行**分隔；
  /// - 顺序固定为：前文上下文 → 上一版原文 → 上一版译文 → 稳定性规则；
  /// - `Previous version of the current source` 与
  ///   `Previous translation of the current source` 是**两个不同字段**，
  ///   绝不能拿同一个值填两遍（那会让模型以为译文就是原文，前缀对照失效）。
  String _buildHyMt2Prompt(StreamTranslateRequest request, String targetName) {
    final previousSource = request.previousSource.trim();
    final previousTranslation = request.previousTranslation.trim();

    // 首译：三个可选项全空时才走整句锚点短模板。
    //
    // 注意判断条件必须与官方 renderer 完全一致：
    // `if not history and not previous_source and not previous_translation`。
    // 漏判 previousSource 会让「已有上一版原文但还没有译文」的状态误走短模板，
    // 把上一版原文丢掉。
    if (previousSource.isEmpty &&
        previousTranslation.isEmpty &&
        request.recentSources.isEmpty) {
      return 'Translate the following text from ${_sourceName()} '
          'into $targetName. Note that you should only output the '
          'translated result without any additional explanation:\n\n'
          '${request.text.trim()}';
    }

    // 逐块收集，最后用空行拼接 —— 与官方 renderer 的 blocks 列表一致。
    final blocks = <String>[];

    if (request.recentSources.isNotEmpty) {
      // source-only 变体（官方支持的另一种历史块，二者不可混用）
      final lines = request.recentSources.map((line) => line.trim());
      blocks.add('Recent source utterances:\n${lines.join('\n')}');
    }

    if (previousSource.isNotEmpty) {
      blocks.add(
        'Previous version of the current source:\n$previousSource',
      );
    }

    if (previousTranslation.isNotEmpty) {
      blocks.add(
        'Previous translation of the current source:\n$previousTranslation',
      );
    }

    // 稳定性规则块：官方 renderer 默认恒开（stability_rule=True）
    blocks.add(
      'When the source meaning has not changed, preserve the still-correct '
      'prefix of the previous translation whenever possible. When content is '
      'added or corrected, accuracy and completeness take priority.',
    );

    return '[Background Information]\n'
        '${blocks.join('\n\n')}\n\n'
        'Please translate the following text from ${_sourceName()} '
        'into $targetName, taking the provided background information '
        'into consideration.\n\n'
        '[Source Text]\n'
        '${request.text.trim()}';
  }

  String _sourceName() => LanguageRegistry.mtPromptName(sourceLanguage);

  // ---------------------------------------------------------------------------
  // Hy 系列 chat 模板包装（**P0：漏了它模型输出的就是原文或乱码**）
  // ---------------------------------------------------------------------------

  /// Hy-MT2 / Hy-MT3 共用的单轮 user wrapper
  ///
  /// 两个模型的发布卡都明确要求 prompt 必须放在这个包装里，否则等于
  /// 给模型喂了一段「无角色的裸文本」，模型不知道自己是 assistant、
  /// 也不知道该不该只输出译文：
  ///
  /// - Hy-MT3 卡：「GGUF 内已写入标准 `tokenizer.chat_template`…
  ///   同样支持直接调用 `/v1/chat/completions`」
  /// - Hy-MT2 / LoRA 卡：「Use one user turn. `apply_chat_template` handles
  ///   the wrapper; for a raw completion endpoint the exact form is:
  ///   `<｜hy_begin▁of▁sentence｜><｜hy_User｜>{PROMPT}<｜hy_Assistant｜>`」，
  ///   并特别强调「**There is no trailing newline**」
  ///
  /// ### 为什么手工拼、不走 `ChatTemplate.apply`
  ///
  /// `ChatTemplate.apply` 依赖 llama.cpp 对 Jinja 模板的**模式识别**，
  /// 认不出就抛 `ChatTemplateException`（见该类的文档注释）。这两份 GGUF
  /// 的模板格式不在 llama.cpp 的已知列表里，走它等于赌运气。
  ///
  /// 而手工拼是**官方明确给出的 raw completion 形式**，不依赖模式识别：
  /// 三个特殊标记在词表里都是独立 token，`parseSpecial: true` 会正确切开。
  ///
  /// ### 字符码点（**不要手打，容易错**）
  ///
  /// - `｜` = U+FF5C（全角竖线），**不是** ASCII `|`(U+007C)
  /// - `▁` = U+2581（lower one eighth block），**不是**下划线 `_`(U+005F)
  ///
  /// 这两个字符打错不会报错，只会让模型收到一段无法识别的裸文本，
  /// 表现仍然是「输出原文 / 乱码」—— 与本 bug 的原症状完全一样，
  /// 极难二次排查。所以集中在下面这两个常量里，只此一处。
  static const String _hyWrapperBegin = '<\uFF5Chy_begin\u2581of\u2581sentence\uFF5C>';

  static const String _hyWrapperUserOpen = '<\uFF5Chy_User\uFF5C>';

  static const String _hyWrapperAssistantOpen = '<\uFF5Chy_Assistant\uFF5C>';

  /// 把裸 prompt 包成单轮 user 对话
  ///
  /// 结尾**不加换行**（模型卡明确要求），最后一个字符是 assistant 起始标记。
  String wrapAsHyChat(String prompt) =>
      '$_hyWrapperBegin$_hyWrapperUserOpen$prompt$_hyWrapperAssistantOpen';

  /// 按当前模板风格渲染 prompt（**已含 chat 包装，可直接喂给 generate**）
  ///
  /// 返回的字符串是完整的、可直接喂给 `EngineSession.generate` 的 prompt：
  /// 内含 `<｜hy_begin▁of▁sentence｜><｜hy_User｜>…<｜hy_Assistant｜>`，
  /// 因此调用 generate 时**必须** `addSpecial: false`（否则会重复加 BOS）。
  String buildPrompt(StreamTranslateRequest request) {
    final body = switch (_promptStyle) {
      // Hy-MT3 要求中文语言名
      MtPromptStyle.hyMt3Stream => _buildHyMt3Prompt(
          request,
          LanguageRegistry.mtPromptNameZh(targetLanguage),
        ),
      // Hy-MT2 要求英文全称
      MtPromptStyle.hyMt2Stream => _buildHyMt2Prompt(
          request,
          LanguageRegistry.mtPromptName(targetLanguage),
        ),
    };
    return wrapAsHyChat(body);
  }

  /// 未包装的 prompt 正文（仅诊断 / 测试用，不要喂给模型）
  String buildPromptBody(StreamTranslateRequest request) {
    switch (_promptStyle) {
      case MtPromptStyle.hyMt3Stream:
        return _buildHyMt3Prompt(
          request,
          LanguageRegistry.mtPromptNameZh(targetLanguage),
        );
      case MtPromptStyle.hyMt2Stream:
        return _buildHyMt2Prompt(
          request,
          LanguageRegistry.mtPromptName(targetLanguage),
        );
    }
  }

  // ---------------------------------------------------------------------------
  // 翻译
  // ---------------------------------------------------------------------------

  /// 流式翻译（带修订上下文）
  ///
  /// 每收到一个 token 就通过 [onChunk] 上报**累计**文本（不是增量），
  /// 这样上层可以整体替换显示，不必自己拼。
  Future<void> translateStreamRevise({
    required StreamTranslateRequest request,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    final session = _session;
    if (session == null || !_modelReady) {
      onError(StateError('LlamaMT 未就绪'), StackTrace.current);
      return;
    }
    if (request.isEmpty) {
      onComplete(
        MTResult(
          sourceText: request.text,
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
    _activeDone = done;
    StreamSubscription<GenerationEvent>? sub;

    // 记录「本次生成整体结束」信号，供下一次请求 await。
    //
    // 这一步是修「cancel 后 await done.future 永久挂住」的关键：
    // 下一次请求先 `await _inflight`，才能保证订阅真的取消了、
    // session 空闲了，再去 `session.clear()`。
    final inflightDone = Completer<void>();
    _inflight = inflightDone.future;

    try {
      // 每句都从干净上下文开始：不清的话 token 历史 + KV 会一路累加，
      // 而且上一句的 KV 会污染当前句的 prefill。
      await session.clear();

      final rawStream = session.generate(
        // buildPrompt() 返回的已经是**完整** prompt：
        // `<｜hy_begin▁of▁sentence｜><｜hy_User｜>{body}<｜hy_Assistant｜>`
        // 已经手工拼好（见 wrapAsHyChat）。所以这里必须 `addSpecial: false`，
        // 否则 tokenizer 会再加一次 BOS，prompt 开头变成两个 BOS token，
        // 模型表现会明显变差。
        //
        // `parseSpecial` 保持默认 true：wrapper 里的三个标记都是词表中的
        // 独立 special token，必须被识别成 token 而不是普通文本。
        prompt: buildPrompt(request),
        addSpecial: false,
        sampler: _sampler,
        maxTokens: _maxTokens,
      );

      // 单次事件间隔兜底：低端机上 prefill 可能要几秒，
      // 但 20s 都没有新 token 基本就是卡死，必须切断避免 UI 永久转圈。
      //
      // 为什么是 20s 而不是旧的 45s：流式字幕每 300ms 就可能来一次新请求，
      // 一次卡 45s 会把整条字幕链路堵死。宁可丢弃当前这次，让下一次重试。
      final guarded = rawStream.timeout(
        const Duration(seconds: 20),
        onTimeout: (sink) {
          sink.addError(TimeoutException('翻译超时（20s 无新 token）'));
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
              // ## 为什么 chunk 也要过 _stripPromptLeakage
              //
              // 这个回调是「边出 token 边上屏」的数据源。以前它是空实现，
              // 泄漏只能在最终结果里被洗掉；现在中间态会直接显示给用户，
              // 一旦模型开头吐了 `【待翻译文本】`，用户会在字幕上看到
              // 半截模板标记再被突然抹掉 —— 观感比不显示还差。
              //
              // 清洗是幂等的：没有标记时原样返回，不会破坏正常文本。
              final partial = _stripPromptLeakage(_buffer.toString());
              if (partial.isEmpty) return;
              onChunk(
                MTChunk(
                  text: partial,
                  isFinal: false,
                  chunkIndex: _buffer.length,
                ),
              );
            case ShiftEvent():
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

      // 被 cancel() 打断：本次结果作废。
      //
      // 必须走 onError 而不是「直接 return」：
      // 上层是用 `Completer<MTResult?>` 等这个回调的，两个回调都不调
      // 就会让 `await completer.future` 永久挂住 —— 那正是本次要修的
      // 那类 bug 的另一种形态。用专门的 TranslationCancelledException
      // 让上层能区分「被更新的识别结果打断」与「真的翻不出来」。
      if (_cancelled) {
        log('[LlamaMT] 本次生成被取消，丢弃结果', name: 'LlamaMT');
        onError(const TranslationCancelledException(), StackTrace.current);
        return;
      }

      final translated = _stripPromptLeakage(_buffer.toString().trim());
      final latency = DateTime.now().difference(startTime);
      onComplete(
        MTResult(
          sourceText: request.text,
          translatedText: translated,
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          latency: latency,
        ),
      );
      log(
        '[LlamaMT] "${request.text}" -> "$translated" '
        '(${latency.inMilliseconds}ms, final=${request.isFinal})',
        name: 'LlamaMT',
      );
    } catch (e, s) {
      _lastError = '翻译失败: $e';
      log('[LlamaMT] 翻译失败: $e\n$s', name: 'LlamaMT');
      onError(e, s);
    } finally {
      _activeSub = null;
      if (identical(_activeDone, done)) _activeDone = null;
      isRunning = false;
      // 通知「本次生成整体结束」：等待方（下一次请求 / dispose）可以往下走了
      if (!inflightDone.isCompleted) inflightDone.complete();
      try {
        await sub?.cancel();
      } catch (_) {
        // 取消本身失败不算错误
      }
    }
  }

  /// 清掉模型偶发的模板泄漏
  ///
  /// 模型卡提到模板/元信息泄漏率是 0/768，但**不是绝对为零**。
  /// 真机上曾经出现过译文里带 `【待翻译文本】` 或 `[Source Text]` 的情况，
  /// 直接上屏会让用户看到莫名其妙的东西，所以在出口处做一次幂等清洗。
  String _stripPromptLeakage(String text) {
    var result = text;
    for (final marker in const [
      '【待翻译文本】',
      '【背景信息】',
      '[Source Text]',
      '[Background Information]',
    ]) {
      final idx = result.lastIndexOf(marker);
      if (idx >= 0) {
        result = result.substring(idx + marker.length).trim();
      }
    }
    return result;
  }

  @override
  Future<void> translateStream({
    required String text,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  }) {
    // 接口兼容路径：单个整句翻译，等价于「已是定稿、无前文、无上一版译文」
    return translateStreamRevise(
      request: StreamTranslateRequest(text: text, isFinal: true),
      onChunk: onChunk,
      onComplete: onComplete,
      onError: onError,
    );
  }

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

  @override
  Future<void> switchLanguagePair(String sourceLang, String targetLang) async {
    final pair = supportedLanguagePairs.firstWhere(
      (p) => p.source == sourceLang && p.target == targetLang,
      orElse: () => throw ArgumentError('不支持的语言对: $sourceLang -> $targetLang'),
    );
    sourceLanguage = pair.source;
    targetLanguage = pair.target;
    log('[LlamaMT] 语言对切换为 $sourceLanguage -> $targetLanguage',
        name: 'LlamaMT');
  }

  /// 中断当前生成（新请求进来时先调，避免串台）
  ///
  /// ## 为什么必须主动 complete `_activeDone`
  ///
  /// `StreamSubscription.cancel()` 只是停止投递事件，**不会**触发 `onDone`。
  /// 旧实现只 cancel 订阅、不 complete completer，于是
  /// `translateStreamRevise` 里的 `await done.future` 永久挂住：
  ///
  /// - `finally` 永远不执行 → `isRunning` 卡在 `true`；
  /// - `_activeSub` 不清空 → 下一次 `cancel()` 取消的还是旧订阅；
  /// - `_inflight` 一直未完成 → 下一次请求的 `await _inflight` 也会挂住。
  ///
  /// 而实时字幕的正常节奏是「ASR 每 ~300ms 更新一次 → 每次都取消上一次」，
  /// 所以这条路径**每次说话都会走到**，不是边角情况。
  ///
  /// 返回的 Future 会在「上一次生成彻底收尾」后完成，调用方应当 await 它
  /// 再发起新请求 —— 否则新请求的 `session.clear()` 会和仍在 worker 中
  /// 运行的旧推理撞车（KV cache 冲突）。
  Future<void> cancel() async {
    _cancelled = true;

    // 先让挂起的 await 解锁，finally 才有机会跑
    final done = _activeDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }

    final sub = _activeSub;
    _activeSub = null;
    try {
      await sub?.cancel();
    } catch (_) {
      // 忽略
    }

    // 等 finally 真正收尾（含 isRunning=false），避免 KV cache 竞态
    final inflight = _inflight;
    if (inflight != null) {
      try {
        await inflight.timeout(const Duration(seconds: 5));
      } catch (_) {
        // 收尾超时也不阻塞新请求：宁可多一次 clear，不要卡死字幕
      }
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
  Future<void> _teardownQuietly() async {
    // 先解锁可能正在 await done.future 的生成。
    //
    // 不做这一步的话：dispose 时若正好有一次翻译在跑，
    // sub.cancel() 不触发 onDone → 那个生成会一直挂在 done.future 上，
    // 而这里紧接着就要 session.dispose()，等于在别人还在用的时候拆掉它。
    final done = _activeDone;
    _activeDone = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }

    final sub = _activeSub;
    _activeSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}

    // 等生成收尾（最多 5s）：避免与 session.dispose() 抢 KV cache
    final inflight = _inflight;
    _inflight = null;
    if (inflight != null) {
      try {
        await inflight.timeout(const Duration(seconds: 5));
      } catch (_) {
        // 收尾超时也要继续释放：宁可多等，不能泄漏 isolate
      }
    }

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