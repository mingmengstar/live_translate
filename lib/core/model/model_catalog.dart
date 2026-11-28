/// 模型清单（下载源唯一事实来源）
///
/// ## v0.8.0：只保留中日英 + 两个 StreamRevise 流式翻译模型
///
/// ### 为什么换成 StreamRevise 系列
///
/// 旧版用 `Hy-MT1.5-1.8B` 做「整句翻译」：等 ASR 吐出一整句（isFinal），
/// 再一次性送进模型。这条路在实时字幕场景下有两个硬伤：
///
/// 1. **延迟等于一整句的说话时长** —— 用户说完才发现译文，不叫实时；
/// 2. 通用翻译指令不携带「上一版译文」，ASR 每次纠错都会让译文跳变。
///
/// 现在换成 `febilly/Hy-MT2` 与 `Hy-MT3` 的 **StreamRevise** 微调版，
/// 它们是为流式字幕**专门训练**的：每次 ASR 局部更新都把
/// 「当前识别文本 + 上一版译文 + 前文上下文 + 进行中/本句结束」
/// 一起喂进去，模型会尽量沿用已经正确的前缀，只改写变化的部分。
///
/// ### ⚠️ 两个模型的提示词格式**不兼容**
///
/// | 模型 | 结构标记 | 目标语言写法 |
/// |---|---|---|
/// | Hy-MT3 | `【背景信息】/【待翻译文本】`（中文标记） | 中文名 `日语` |
/// | Hy-MT2 | `[Background Information]/[Source Text]`（英文标记） | 英文名 `Japanese` |
///
/// 用混了**不会报错**，只会输出原文或乱码 —— 这是最难排查的一类问题。
/// 所以 `MtPromptStyle` 必须由清单显式指定，且渲染逻辑严格分开。
///
/// ### 体积与内存
///
/// 两个模型都是 1.8B / Q4_K_M，约 1.0~1.06 GiB。手机上 n_ctx=2048 时
/// 权重 + KV cache 约 1.2 GiB，因此要求至少 2GB 可用内存。
///
/// ### 校验策略（沿用 v0.6.0）
///
/// 只校验「写入字节数 == 服务端声明字节数」（能挡住截断）。
/// 不算 SHA-256：1GB 级文件在手机上算一次要几十秒，且镜像改写字节会
/// 陷入「下完 → 校验失败 → 重下」死循环。真正的损坏会在 llama.cpp
/// 加载阶段立刻报错。
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

/// 识别模型选项（**仅中日英**）
///
/// 每一项都对应 sherpa-onnx 官方 HuggingFace 仓库里的一套
/// `encoder / decoder / joiner / tokens` 四件套。
///
/// 已删除：korean / french / german / spanish / russian。
/// 那些语种的翻译模型根本没训练过，留着只会误导用户。
enum AsrModelVariant {
  /// 中英双语（2023 老版，体积/精度平衡，中英混说最常用）
  zhEn,

  /// 中英双语 + 标点（2026-06 新版，480ms 低延迟）
  zhEnPunct,

  /// 中文（2025-06-30 新版权威模型）
  chinese,

  /// 英语（Kroko 2025-08，比 2023 版更准）
  english,

  /// 多语种（含中/英/日，日语识别用它）
  multilingual,
}

/// 翻译（MT）权重选项 —— 只有两个 StreamRevise 流式模型
enum MtModelVariant {
  /// Hy-MT2 1.8B StreamRevise v4（约 1.07GB）
  hyMt2StreamRevise,

  /// Hy-MT3 1.8B StreamRevise（约 1.13GB，更新版）
  hyMt3StreamRevise,
}

/// 提示词模板风格
///
/// 两个 StreamRevise 模型的模板**结构和语言都不同**，必须严格区分：
/// 用错不会报错，只会输出原文 / 乱码。
enum MtPromptStyle {
  /// Hy-MT3 StreamRevise：中文标记 + 中文语言名
  /// （`【背景信息】` / `【待翻译文本】` / `状态：进行中|本句结束`）
  hyMt3Stream,

  /// Hy-MT2 StreamRevise v4：英文标记 + 英文语言名
  /// （`[Background Information]` / `[Source Text]`）
  hyMt2Stream,
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
  // 翻译模型（StreamRevise 流式字幕专用 GGUF）
  // ---------------------------------------------------------------------------

  /// Hy-MT2 1.8B StreamRevise v4（Q4_K_M，约 1.07GB）
  ///
  /// 特点：每次 ASR 更新都带上「上一版译文」，模型倾向于沿用正确前缀。
  /// 提示词用**英文**标记与英文语言名。
  static const RemoteModelFile _hyMt2StreamRevise = RemoteModelFile(
    fileName: 'hy-mt2-1.8b-stream-revise-q4_k_m.gguf',
    url: 'https://huggingface.co/'
        'febilly/Hy-MT2-1.8B-StreamRevise-v4-GGUF/'
        'resolve/main/Hy-MT2-1.8B-StreamRevise-v4-Q4_K_M.gguf',
    sizeBytes: 1069288640,
    role: ModelFileRole.mt,
  );

  /// Hy-MT3 1.8B StreamRevise（Q4_K_M，约 1.13GB）
  ///
  /// 比 v4 更新，加入了「进行中 / 本句结束」的标点控制：
  /// 半句时不会乱补句号，定稿时才收尾。
  /// 提示词用**中文**标记与中文语言名。
  static const RemoteModelFile _hyMt3StreamRevise = RemoteModelFile(
    fileName: 'hy-mt3-1.8b-stream-revise-q4_k_m.gguf',
    url: 'https://huggingface.co/'
        'febilly/Hy-MT3-1.8B-StreamRevise-GGUF/'
        'resolve/main/Hy-MT3-1.8B-StreamRevise-Q4_K_M.gguf',
    sizeBytes: 1133080672,
    role: ModelFileRole.mt,
  );

  static const Map<MtModelVariant, RemoteModelFile> _mtFiles = {
    MtModelVariant.hyMt2StreamRevise: _hyMt2StreamRevise,
    MtModelVariant.hyMt3StreamRevise: _hyMt3StreamRevise,
  };

  static const Map<MtModelVariant, MtModelSpec> _mtSpecs = {
    MtModelVariant.hyMt2StreamRevise: MtModelSpec(
      variant: MtModelVariant.hyMt2StreamRevise,
      label: 'Hy-MT2 1.8B 流式',
      description: '约 1.07GB · 流式字幕专用，沿用语向更稳，需 2GB 可用内存。',
      promptStyle: MtPromptStyle.hyMt2Stream,
      minFreeRamBytes: 2 << 30,
    ),
    MtModelVariant.hyMt3StreamRevise: MtModelSpec(
      variant: MtModelVariant.hyMt3StreamRevise,
      label: 'Hy-MT3 1.8B 流式',
      description: '约 1.13GB · 最新版，半句不补标点、定稿才收尾，推荐。',
      promptStyle: MtPromptStyle.hyMt3Stream,
      minFreeRamBytes: 2 << 30,
    ),
  };

  /// 翻译模型规格
  static MtModelSpec mtSpec(MtModelVariant variant) =>
      _mtSpecs[variant] ?? _mtSpecs[MtModelVariant.hyMt3StreamRevise]!;

  /// 翻译模型文件
  static RemoteModelFile mtFileFor(MtModelVariant variant) =>
      _mtFiles[variant] ?? _hyMt3StreamRevise;

  /// 翻译模型显示名（UI 用）
  static final Map<MtModelVariant, String> mtVariantLabels = {
    for (final entry in _mtSpecs.entries) entry.key: entry.value.label,
  };

  /// 翻译模型说明（UI 用）
  static final Map<MtModelVariant, String> mtVariantDetails = {
    for (final entry in _mtSpecs.entries) entry.key: entry.value.description,
  };

  /// 默认翻译模型（Hy-MT3，最新且标点控制更好）
  static const RemoteModelFile defaultMt = _hyMt3StreamRevise;

  // ---------------------------------------------------------------------------
  // 识别模型（sherpa-onnx zipformer transducer 四件套）
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
    AsrModelVariant.zhEnPunct: [
      RemoteModelFile(
        fileName: 'encoder-zh-en-punct-int8.onnx',
        url: 'https://huggingface.co/'
            'lorneluo/sherpa-onnx-x-asr-480ms-streaming-zipformer-'
            'transducer-zh-en-punct-int8-2026-06-05/'
            'resolve/main/encoder.int8.onnx',
        sizeBytes: 155278641,
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-zh-en-punct.onnx',
        url: 'https://huggingface.co/'
            'lorneluo/sherpa-onnx-x-asr-480ms-streaming-zipformer-'
            'transducer-zh-en-punct-int8-2026-06-05/'
            'resolve/main/decoder.onnx',
        sizeBytes: 11309084,
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-zh-en-punct-int8.onnx',
        url: 'https://huggingface.co/'
            'lorneluo/sherpa-onnx-x-asr-480ms-streaming-zipformer-'
            'transducer-zh-en-punct-int8-2026-06-05/'
            'resolve/main/joiner.int8.onnx',
        sizeBytes: 2581422,
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-zh-en-punct.txt',
        url: 'https://huggingface.co/'
            'lorneluo/sherpa-onnx-x-asr-480ms-streaming-zipformer-'
            'transducer-zh-en-punct-int8-2026-06-05/'
            'resolve/main/tokens.txt',
        sizeBytes: 58806,
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
  };

  /// 语种显示名
  static const Map<AsrModelVariant, String> asrVariantLabels = {
    AsrModelVariant.zhEn: '中英双语',
    AsrModelVariant.zhEnPunct: '中英双语（带标点）',
    AsrModelVariant.chinese: '中文',
    AsrModelVariant.english: '英语',
    AsrModelVariant.multilingual: '中日英（多语种）',
  };

  /// 语种覆盖说明
  static const Map<AsrModelVariant, String> asrVariantDetails = {
    AsrModelVariant.zhEn: '中文 + 英语混说，约 197MB，2023 稳定版',
    AsrModelVariant.zhEnPunct: '中文 + 英语，480ms 低延迟，自带标点，2026-06 新模型，约 165MB',
    AsrModelVariant.chinese: '仅中文，2025-06-30 权威版，约 167MB',
    AsrModelVariant.english: '仅英语，Kroko 2025-08 新版，约 68MB',
    AsrModelVariant.multilingual: '中日英通用（含日语），约 340MB',
  };

  static List<RemoteModelFile> asrFilesFor(AsrModelVariant variant) =>
      _asrVariants[variant] ?? const [];

  /// 组装一个可下载包
  ///
  /// [withTranslation] 为 true 时附带翻译模型（由 [mtVariant] 决定是哪一份）。
  /// [withVad] 为 true 时附带 Silero VAD（+约 630KB）。
  static ModelPack pack({
    AsrModelVariant variant = AsrModelVariant.multilingual,
    MtModelVariant mtVariant = MtModelVariant.hyMt3StreamRevise,
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
      case 'ja':
        return AsrModelVariant.multilingual;
      case 'zh':
        return AsrModelVariant.chinese;
      case 'en':
        return AsrModelVariant.english;
      default:
        // 中日英任意组合场景的默认：多语种模型一套覆盖三种语言
        return AsrModelVariant.multilingual;
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