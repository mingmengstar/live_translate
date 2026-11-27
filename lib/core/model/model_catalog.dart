/// 模型清单（下载源唯一事实来源）
///
/// 所有条目均由真实网络实测确认（HuggingFace / GitHub 官方发布物），非占位：
/// - `url`：HuggingFace `resolve/main` 或 GitHub release 直链
///   （均支持 HTTP Range，可断点续传）
/// - `sizeBytes`：服务端声明的准确字节数
///
/// ## v0.6.0：移除 SHA-256 校验
///
/// 旧实现下载完每个文件都要现算一遍 SHA-256。1.06GB 的翻译权重在手机上
/// 算一次要几十秒；更糟的是只要镜像 / 代理改写了字节，就会
/// 「下完 → 校验失败 → 删掉重下」，陷入永远下不完的死循环。
///
/// 现在只校验「字节数是否等于服务端声明值」：
/// - 能挡住截断（`written != sizeBytes` 即视为不完整，保留 `.part` 续传）；
/// - 真正的模型损坏会在 `llama.cpp` / `sherpa-onnx` 加载阶段立刻报错，
///   而不是让用户在下载阶段白等几十分钟。
///
/// 设计要点：
/// - **不写死单一模型**：同一「语言包」可选不同语种的识别模型；
/// - **VAD 独立**：Silero VAD 是所有语言包共用组件，缺失时降级能量 VAD；
/// - **翻译模型单独成组**：体积最大，允许「先只下识别模型」的渐进式安装。
library live_translate.core.model.model_catalog;

import 'model_storage.dart';

/// 单个可下载文件
class RemoteModelFile {
  const RemoteModelFile({
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    required this.role,
  });

  /// 落盘后的文件名（统一扁平命名，避免官方包内超长名）
  final String fileName;

  /// 直链下载地址
  final String url;

  /// 期望字节数（用于进度预估与下载完整性判定）
  final int sizeBytes;

  /// 该文件属于哪个功能角色
  final ModelFileRole role;

  String get sizeLabel => humanSize(sizeBytes);

  /// 字节数转人类可读体积
  static String humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)}'
        '${units[unit]}';
  }
}

/// 文件功能角色
enum ModelFileRole {
  /// 语音识别编码器
  asrEncoder,

  /// 语音识别解码器
  asrDecoder,

  /// 语音识别 joiner
  asrJoiner,

  /// 识别词表
  asrTokens,

  /// 语音活动检测
  vad,

  /// 机器翻译权重
  mt,
}

/// 一组可直接「一键下载」的模型组合
class ModelPack {
  const ModelPack({
    required this.id,
    required this.label,
    required this.description,
    required this.files,
    this.mtSpec,
  });

  /// 稳定标识（用于持久化选择）
  final String id;

  /// 界面显示名
  final String label;

  /// 一句话说明（语种覆盖、体积权衡等）
  final String description;

  final List<RemoteModelFile> files;

  /// 若包含翻译模型，携带它的规格（提示词模板 / 内存需求）
  final MtModelSpec? mtSpec;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  String get totalSizeLabel => RemoteModelFile.humanSize(totalBytes);

  bool get includesTranslation => files.any((f) => f.role == ModelFileRole.mt);

  List<RemoteModelFile> get asrFiles => files
      .where((f) => f.role != ModelFileRole.mt && f.role != ModelFileRole.vad)
      .toList();

  RemoteModelFile? get mtFile {
    for (final f in files) {
      if (f.role == ModelFileRole.mt) return f;
    }
    return null;
  }
}

/// 识别模型选项（按语种区分）
///
/// 每一项都对应 sherpa-onnx 官方 HuggingFace 仓库里的一套
/// `encoder / decoder / joiner / tokens` 四件套。
enum AsrModelVariant {
  /// 中英双语（体积/精度平衡，中英混说场景最常用）
  zhEn,

  /// 中文（2025-06-30 新版权威模型）
  chinese,

  /// 英语（Kroko 2025-08，比 2023 版更准）
  english,

  /// 韩语专用
  korean,

  /// 八语种多语言（含日/英/中/俄/泰/越/阿/印尼）
  multilingual,

  /// 法语（Kroko 2025-08）
  french,

  /// 德语（Kroko 2025-08）
  german,

  /// 西班牙语（Kroko 2025-08）
  spanish,

  /// 俄语（Vosk 小模型 int8，体积仅约 28MB）
  russian,
}

/// 翻译（MT）权重选项
///
/// 全部是 llama.cpp 可直接加载的 GGUF，来源都是模型官方仓库。
enum MtModelVariant {
  /// Hy-MT1.5 1.8B Q4_K_M（默认，约 1.06GB）
  hyMt15Q4,

  /// Hy-MT1.5 1.8B Q8_0（质量更好，约 1.78GB）
  hyMt15Q8,

  /// Hy-MT1.5 7B Q4_K_M（质量最好，约 4.31GB，需 8GB 可用内存）
  hyMt7bQ4,

  /// Qwen2.5 0.5B Instruct Q4_K_M（极轻量通用小模型，约 469MB）
  qwen25_05b,
}

/// 提示词模板风格
///
/// 不同翻译模型的指令格式完全不同，写错会直接输出原文或乱码。
enum MtPromptStyle {
  /// 混元 Hy-MT1.5 官方模板
  /// （`<|startoftext|>Translate the following segment into {target},
  /// without additional explanation.`）
  hyMt,

  /// ChatML（Qwen 等 instruct 模型通用）
  chatMl,
}

/// 翻译模型规格
class MtModelSpec {
  const MtModelSpec({
    required this.variant,
    required this.label,
    required this.description,
    required this.promptStyle,
    required this.minFreeRamBytes,
  });

  final MtModelVariant variant;

  /// 界面显示名
  final String label;

  /// 一句话说明（体积 / 质量 / 内存权衡）
  final String description;

  /// 提示词模板
  final MtPromptStyle promptStyle;

  /// 建议的最小可用内存（低于此值加载会 OOM）
  final int minFreeRamBytes;

  String get minFreeRamLabel => RemoteModelFile.humanSize(minFreeRamBytes);
}

/// 全局模型清单
class ModelCatalog {
  ModelCatalog._();

  /// Silero VAD（所有语言包共用，约 630KB）
  static const RemoteModelFile sileroVad = RemoteModelFile(
    fileName: 'silero_vad.onnx',
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
        'asr-models/silero_vad.onnx',
    sizeBytes: 643854,
    role: ModelFileRole.vad,
  );

  // ---------------------------------------------------------------------------
  // 翻译模型（GGUF，llama.cpp 直接加载）
  // ---------------------------------------------------------------------------

  /// Hy-MT1.5 1.8B Q4_K_M（推荐：体积/质量平衡点）
  static const RemoteModelFile _hyMt15Q4 = RemoteModelFile(
    fileName: 'hy-mt1.5-1.8b-q4_k_m.gguf',
    url: 'https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/'
        'resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf',
    sizeBytes: 1133080512,
    role: ModelFileRole.mt,
  );

  /// Hy-MT1.5 1.8B Q8_0（质量更好，内存翻倍）
  static const RemoteModelFile _hyMt15Q8 = RemoteModelFile(
    fileName: 'hy-mt1.5-1.8b-q8_0.gguf',
    url: 'https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/'
        'resolve/main/HY-MT1.5-1.8B-Q8_0.gguf',
    sizeBytes: 1908528288,
    role: ModelFileRole.mt,
  );

  /// Hy-MT1.5 7B Q4_K_M（旗舰质量，手机上属于「能跑但吃力」）
  static const RemoteModelFile _hyMt7bQ4 = RemoteModelFile(
    fileName: 'hy-mt1.5-7b-q4_k_m.gguf',
    url: 'https://huggingface.co/tencent/HY-MT1.5-7B-GGUF/'
        'resolve/main/HY-MT1.5-7B-Q4_K_M.gguf',
    sizeBytes: 4624649312,
    role: ModelFileRole.mt,
  );

  /// Qwen2.5 0.5B Instruct Q4_K_M（极轻量，适合低端机 / 只要「够用」）
  static const RemoteModelFile _qwen25_05b = RemoteModelFile(
    fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/'
        'resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sizeBytes: 491400032,
    role: ModelFileRole.mt,
  );

  static const Map<MtModelVariant, RemoteModelFile> _mtFiles = {
    MtModelVariant.hyMt15Q4: _hyMt15Q4,
    MtModelVariant.hyMt15Q8: _hyMt15Q8,
    MtModelVariant.hyMt7bQ4: _hyMt7bQ4,
    MtModelVariant.qwen25_05b: _qwen25_05b,
  };

  static const Map<MtModelVariant, MtModelSpec> _mtSpecs = {
    MtModelVariant.hyMt15Q4: MtModelSpec(
      variant: MtModelVariant.hyMt15Q4,
      label: 'Hy-MT1.5 1.8B Q4',
      description: '约 1.06GB · 推荐。中文翻译质量好，主流手机可流畅运行。',
      promptStyle: MtPromptStyle.hyMt,
      minFreeRamBytes: 2 << 30,
    ),
    MtModelVariant.hyMt15Q8: MtModelSpec(
      variant: MtModelVariant.hyMt15Q8,
      label: 'Hy-MT1.5 1.8B Q8',
      description: '约 1.78GB · 量化损失更小，译文更稳，需 4GB 可用内存。',
      promptStyle: MtPromptStyle.hyMt,
      minFreeRamBytes: 4 << 30,
    ),
    MtModelVariant.hyMt7bQ4: MtModelSpec(
      variant: MtModelVariant.hyMt7bQ4,
      label: 'Hy-MT1.5 7B Q4',
      description: '约 4.31GB · 质量最好，但需 8GB 以上可用内存，低端机会 OOM。',
      promptStyle: MtPromptStyle.hyMt,
      minFreeRamBytes: 8 << 30,
    ),
    MtModelVariant.qwen25_05b: MtModelSpec(
      variant: MtModelVariant.qwen25_05b,
      label: 'Qwen2.5 0.5B',
      description: '约 469MB · 极轻量通用小模型，速度快但译文不如专用模型。',
      promptStyle: MtPromptStyle.chatMl,
      minFreeRamBytes: 1 << 30,
    ),
  };

  /// 翻译模型规格
  static MtModelSpec mtSpec(MtModelVariant variant) =>
      _mtSpecs[variant] ?? _mtSpecs[MtModelVariant.hyMt15Q4]!;

  /// 翻译模型文件
  static RemoteModelFile mtFileFor(MtModelVariant variant) =>
      _mtFiles[variant] ?? _hyMt15Q4;

  /// 翻译模型显示名（UI 用）
  static final Map<MtModelVariant, String> mtVariantLabels = {
    for (final entry in _mtSpecs.entries) entry.key: entry.value.label,
  };

  /// 翻译模型说明（UI 用）
  static final Map<MtModelVariant, String> mtVariantDetails = {
    for (final entry in _mtSpecs.entries) entry.key: entry.value.description,
  };

  /// 兼容旧名：默认翻译模型（Hy-MT1.5 1.8B Q4_K_M）
  static const RemoteModelFile hyMt15 = _hyMt15Q4;

  // ---------------------------------------------------------------------------
  // 识别模型（sherpa-onnx zipformer2 transducer 四件套）
  // ---------------------------------------------------------------------------

  static const Map<AsrModelVariant, List<RemoteModelFile>> _asrVariants = {
    AsrModelVariant.zhEn: [
      RemoteModelFile(
        fileName: 'encoder-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/encoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 181895032,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/decoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 13091040,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/joiner-epoch-99-avg-1.int8.onnx',
        sizeBytes: 3228404,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-zh-en.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/tokens.txt',
        sizeBytes: 56317,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.chinese: [
      RemoteModelFile(
        fileName: 'encoder-zh-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/'
            'resolve/main/encoder.int8.onnx',
        sizeBytes: 161141793,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-zh.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/'
            'resolve/main/decoder.onnx',
        sizeBytes: 5165083,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-zh-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/'
            'resolve/main/joiner.int8.onnx',
        sizeBytes: 1033416,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-zh.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30/'
            'resolve/main/tokens.txt',
        sizeBytes: 20628,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.english: [
      RemoteModelFile(
        fileName: 'encoder-en-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/'
            'resolve/main/encoder.onnx',
        sizeBytes: 70092599,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-en-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/'
            'resolve/main/decoder.onnx',
        sizeBytes: 617488,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-en-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/'
            'resolve/main/joiner.onnx',
        sizeBytes: 336817,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-en-kroko.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06/'
            'resolve/main/tokens.txt',
        sizeBytes: 6310,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.korean: [
      RemoteModelFile(
        fileName: 'encoder-ko-int8.onnx',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/encoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 126968852,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-ko-int8.onnx',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/decoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 2844692,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-ko-int8.onnx',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/joiner-epoch-99-avg-1.int8.onnx',
        sizeBytes: 2581421,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-ko.txt',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/tokens.txt',
        sizeBytes: 60246,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.multilingual: [
      RemoteModelFile(
        fileName: 'encoder-multi-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
        sizeBytes: 296583597,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-multi.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
        sizeBytes: 33837085,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-multi-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
        sizeBytes: 8257421,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-multi.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/tokens.txt',
        sizeBytes: 195244,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.french: [
      RemoteModelFile(
        fileName: 'encoder-fr-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/'
            'resolve/main/encoder.onnx',
        sizeBytes: 70092599,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-fr-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/'
            'resolve/main/decoder.onnx',
        sizeBytes: 617488,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-fr-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/'
            'resolve/main/joiner.onnx',
        sizeBytes: 336817,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-fr-kroko.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/'
            'resolve/main/tokens.txt',
        sizeBytes: 5415,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.german: [
      RemoteModelFile(
        fileName: 'encoder-de-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/'
            'resolve/main/encoder.onnx',
        sizeBytes: 70091557,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-de-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/'
            'resolve/main/decoder.onnx',
        sizeBytes: 617489,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-de-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/'
            'resolve/main/joiner.onnx',
        sizeBytes: 336817,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-de-kroko.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/'
            'resolve/main/tokens.txt',
        sizeBytes: 5606,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.spanish: [
      RemoteModelFile(
        fileName: 'encoder-es-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/'
            'resolve/main/encoder.onnx',
        sizeBytes: 154878102,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-es-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/'
            'resolve/main/decoder.onnx',
        sizeBytes: 617488,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-es-kroko.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/'
            'resolve/main/joiner.onnx',
        sizeBytes: 336817,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-es-kroko.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/'
            'resolve/main/tokens.txt',
        sizeBytes: 6385,
        role: ModelFileRole.asrTokens,
      ),
    ],
    AsrModelVariant.russian: [
      RemoteModelFile(
        fileName: 'encoder-ru-vosk-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16/'
            'resolve/main/encoder.int8.onnx',
        sizeBytes: 26214060,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-ru-vosk.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16/'
            'resolve/main/decoder.onnx',
        sizeBytes: 2093080,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-ru-vosk-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16/'
            'resolve/main/joiner.int8.onnx',
        sizeBytes: 259417,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-ru-vosk.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-small-ru-vosk-int8-2025-08-16/'
            'resolve/main/tokens.txt',
        sizeBytes: 6388,
        role: ModelFileRole.asrTokens,
      ),
    ],
  };

  /// 语种显示名
  static const Map<AsrModelVariant, String> asrVariantLabels = {
    AsrModelVariant.zhEn: '中英双语',
    AsrModelVariant.chinese: '中文',
    AsrModelVariant.english: '英语',
    AsrModelVariant.korean: '韩语',
    AsrModelVariant.multilingual: '八语种',
    AsrModelVariant.french: '法语',
    AsrModelVariant.german: '德语',
    AsrModelVariant.spanish: '西班牙语',
    AsrModelVariant.russian: '俄语',
  };

  /// 语种覆盖说明
  static const Map<AsrModelVariant, String> asrVariantDetails = {
    AsrModelVariant.zhEn: '中文 + 英语混说都行，约 197MB，最推荐',
    AsrModelVariant.chinese: '纯中文，2025-06-30 新版权威模型，约 167MB',
    AsrModelVariant.english: '纯英语，Kroko 2025-08 新版，约 68MB',
    AsrModelVariant.korean: '仅韩语，约 133MB',
    AsrModelVariant.multilingual:
        '阿拉伯/英/印尼/日/俄/泰/越/中（不含韩语），约 340MB',
    AsrModelVariant.french: '纯法语，Kroko 2025-08 版，约 68MB',
    AsrModelVariant.german: '纯德语，Kroko 2025-08 版，约 68MB',
    AsrModelVariant.spanish: '纯西班牙语，Kroko 2025-08 版，约 149MB',
    AsrModelVariant.russian: '纯俄语，Vosk 小模型 int8，约 28MB，最轻',
  };

  static List<RemoteModelFile> asrFilesFor(AsrModelVariant variant) =>
      _asrVariants[variant] ?? const [];

  /// 组装一个可下载包
  ///
  /// [withTranslation] 为 true 时附带翻译模型（由 [mtVariant] 决定是哪一份）。
  /// [withVad] 为 true 时附带 Silero VAD（+约 630KB）。
  static ModelPack pack({
    AsrModelVariant variant = AsrModelVariant.zhEn,
    MtModelVariant mtVariant = MtModelVariant.hyMt15Q4,
    bool withTranslation = true,
    bool withVad = true,
  }) {
    final mt = withTranslation ? mtFileFor(mtVariant) : null;
    final files = <RemoteModelFile>[
      ...asrFilesFor(variant),
      if (withVad) sileroVad,
      if (mt != null) mt,
    ];
    final parts = <String>[asrVariantLabels[variant] ?? ''];
    if (withVad) parts.add('VAD');
    if (mt != null) parts.add(mtSpec(mtVariant).label);
    return ModelPack(
      id: '${variant.name}'
          '${withVad ? '+vad' : ''}'
          '${withTranslation ? '+mt-${mtVariant.name}' : ''}',
      label: parts.where((p) => p.isNotEmpty).join(' + '),
      description: asrVariantDetails[variant] ?? '',
      files: files,
      mtSpec: mt == null ? null : mtSpec(mtVariant),
    );
  }

  /// 按语种代码推荐最合适的识别模型
  ///
  /// 用于「用户先选语言，再一键下载对应模型」的引导流程。
  static AsrModelVariant recommendedFor(String languageCode) {
    switch (languageCode) {
      case 'ko':
        return AsrModelVariant.korean;
      case 'en':
        return AsrModelVariant.english;
      case 'fr':
        return AsrModelVariant.french;
      case 'de':
        return AsrModelVariant.german;
      case 'es':
        return AsrModelVariant.spanish;
      case 'ru':
        return AsrModelVariant.russian;
      case 'ja':
      case 'th':
      case 'vi':
      case 'ar':
      case 'id':
        return AsrModelVariant.multilingual;
      case 'zh':
        return AsrModelVariant.chinese;
      default:
        return AsrModelVariant.zhEn;
    }
  }
}

/// 清单与 ModelStorage 的语义对齐检查
///
/// `ModelStorage.requiredFiles` 是「历史遗留的固定命名」，
/// 而清单用的是分语种命名。两边必须能对上，否则检测永远不通过。
extension ModelCatalogAlignment on ModelCatalog {
  /// 判断某文件是否被 ModelStorage 视为必需
  static bool isTrackedByStorage(RemoteModelFile file) {
    return ModelStorage.requiredFiles
        .any((spec) => spec.fileName == file.fileName);
  }
}