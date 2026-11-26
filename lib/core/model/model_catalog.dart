/// 模型清单（下载源 + 完整性校验基准）
///
/// 所有条目均由真实网络实测确认，非占位：
/// - `downloadUrl`：HuggingFace `resolve/main` 直链（支持 HTTP Range，可断点续传）
/// - `sizeBytes`：服务端声明的准确字节数
/// - `sha256`：文件内容 SHA-256（大文件取自 HF LFS 的 `lfs.oid`，
///   小文件由实际下载后现算，均已核对）
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
    required this.sha256,
    required this.role,
  });

  /// 落盘后的文件名（统一扁平命名，避免官方包内超长名）
  final String fileName;

  /// 直链下载地址
  final String url;

  /// 期望字节数（用于进度预估与校验）
  final int sizeBytes;

  /// SHA-256（小写十六进制，64 字符）
  final String sha256;

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
  });

  /// 稳定标识（用于持久化选择）
  final String id;

  /// 界面显示名
  final String label;

  /// 一句话说明（语种覆盖、体积权衡等）
  final String description;

  final List<RemoteModelFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  String get totalSizeLabel => RemoteModelFile.humanSize(totalBytes);

  bool get includesTranslation =>
      files.any((f) => f.role == ModelFileRole.mt);

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
enum AsrModelVariant {
  /// 中英双语（体积最小，中英混说场景最常用）
  zhEn,

  /// 韩语专用
  korean,

  /// 八语种多语言（含日/英/中/俄/泰/越/阿/印尼）
  multilingual,
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
    // 已实测下载并计算
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    role: ModelFileRole.vad,
  );

  /// Hy-MT1.5-1.8B Q4_K_M 翻译模型（约 1.06GB）
  ///
  /// 1.8B 而非 7B：7B 的 Q4 约 4.4GB，绝大多数手机放不下也用不动。
  static const RemoteModelFile hyMt15 =
      RemoteModelFile(
    fileName: 'hy-mt1.5-1.8b-q4_k_m.gguf',
    url: 'https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/'
        'resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf',
    sizeBytes: 1133080512,
    sha256: '4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7',
    role: ModelFileRole.mt,
  );

  static const Map<AsrModelVariant, List<RemoteModelFile>> _asrVariants = {
    AsrModelVariant.zhEn: [
      RemoteModelFile(
        fileName: 'encoder-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/encoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 181895032,
        sha256:
            '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/decoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 13091040,
        sha256:
            '1a70c593d71e53f023f5f55b0b4cfff5055abb786ee3992e5f63dc2e273cc4fa',
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-zh-en-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/joiner-epoch-99-avg-1.int8.onnx',
        sizeBytes: 3228404,
        sha256:
            '1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0',
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-zh-en.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/'
            'resolve/main/tokens.txt',
        sizeBytes: 56317,
        sha256:
            'a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3',
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
        sha256:
            '8d0b1aa24fbedd4e3948564ab7facd151b8ce9b0c48fc987c541de2de3af5697',
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-ko-int8.onnx',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/decoder-epoch-99-avg-1.int8.onnx',
        sizeBytes: 2844692,
        sha256:
            '68ea197936aabd249f38b53a87c775422bca64428ad4427d0e6e8092593e71fb',
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-ko-int8.onnx',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/joiner-epoch-99-avg-1.int8.onnx',
        sizeBytes: 2581421,
        sha256:
            '128b80a66a1f718488af8560f9d15895109b99ff3e573f0a0130e03774ef1ced',
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-ko.txt',
        url: 'https://huggingface.co/'
            'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/'
            'resolve/main/tokens.txt',
        sizeBytes: 60246,
        sha256:
            '016bdf0965029263b7ad01b742366ee542ef0bef38261510e8176ff6f2e9e668',
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
        sha256:
            'f9001ed7a9e46d0294438c1a30cd7c72d1cc4bdd4e7880edbcda36f67081e32e',
        role: ModelFileRole.asrEncoder,
      ),
      RemoteModelFile(
        fileName: 'decoder-multi.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
        sizeBytes: 33837085,
        sha256:
            '7ebc63f34b21c8efb4a41a5a2eee7fe1448829ce0230ecc5369e67fc14d90d48',
        role: ModelFileRole.asrDecoder,
      ),
      RemoteModelFile(
        fileName: 'joiner-multi-int8.onnx',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
        sizeBytes: 8257421,
        sha256:
            '1db88e3172323551abaa99b91b18fb422a27ea4a834fd0db10389f9478816f91',
        role: ModelFileRole.asrJoiner,
      ),
      RemoteModelFile(
        fileName: 'tokens-multi.txt',
        url: 'https://huggingface.co/'
            'csukuangfj/sherpa-onnx-streaming-zipformer-'
            'ar_en_id_ja_ru_th_vi_zh-2025-02-10/'
            'resolve/main/tokens.txt',
        sizeBytes: 195244,
        sha256:
            '784f24950f6bcce1b0021035632dd60fd4617ecd8ca0581ab57d7b39d77ba5ab',
        role: ModelFileRole.asrTokens,
      ),
    ],
  };

  /// 语种显示名
  static const Map<AsrModelVariant, String> asrVariantLabels = {
    AsrModelVariant.zhEn: '中英双语',
    AsrModelVariant.korean: '韩语',
    AsrModelVariant.multilingual: '八语种多语言',
  };

  /// 语种覆盖说明
  static const Map<AsrModelVariant, String> asrVariantDetails = {
    AsrModelVariant.zhEn: '中文 + 英语混说都行，约 197MB，最推荐',
    AsrModelVariant.korean: '仅韩语，约 133MB',
    AsrModelVariant.multilingual:
        '阿拉伯/英/印尼/日/俄/泰/越/中（不含韩语），约 340MB',
  };

  static List<RemoteModelFile> asrFilesFor(AsrModelVariant variant) =>
      _asrVariants[variant] ?? const [];

  /// 组装一个可下载包
  ///
  /// [withTranslation] 为 true 时附带翻译模型（+约 1.06GB）。
  /// [withVad] 为 true 时附带 Silero VAD（+约 630KB）。
  static ModelPack pack({
    AsrModelVariant variant = AsrModelVariant.zhEn,
    bool withTranslation = true,
    bool withVad = true,
  }) {
    final files = <RemoteModelFile>[
      ...asrFilesFor(variant),
      if (withVad) sileroVad,
      if (withTranslation) hyMt15,
    ];
    final parts = <String>[asrVariantLabels[variant] ?? ''];
    if (withVad) parts.add('VAD');
    if (withTranslation) parts.add('翻译');
    return ModelPack(
      id: '${variant.name}'
          '${withVad ? '+vad' : ''}'
          '${withTranslation ? '+mt' : ''}',
      label: parts.where((p) => p.isNotEmpty).join(' + '),
      description: asrVariantDetails[variant] ?? '',
      files: files,
    );
  }

  /// 按语种代码推荐最合适的识别模型
  ///
  /// 用于「用户先选语言，再一键下载对应模型」的引导流程。
  static AsrModelVariant recommendedFor(String languageCode) {
    switch (languageCode) {
      case 'ko':
        return AsrModelVariant.korean;
      case 'ja':
      case 'ru':
      case 'th':
      case 'vi':
        return AsrModelVariant.multilingual;
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