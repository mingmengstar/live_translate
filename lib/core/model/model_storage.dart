/// 模型文件存储与就绪状态检测
///
/// 本文件负责三件事：
/// 1. 决定模型目录（默认在应用私有目录下，**可被用户改成任意路径**）；
/// 2. 按「功能角色」判定模型是否齐全，而不是死抠某个固定文件名；
/// 3. 为首页 / 导入页 / 下载管线 / 推理引擎提供统一的路径解析。
///
/// 为什么要按角色判定：
/// 识别模型按语种拆分（中英、韩语、八语种多语言），文件名各不相同，
/// 但「有 encoder + decoder + joiner + tokens 就算 ASR 就绪」这个语义不变。
/// 所以检测按前缀规则走，任何合规命名的模型都能被认出来。
library live_translate.core.model.model_storage;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 模型用途分类
enum ModelKind { asr, vad, mt }

/// 单个模型文件描述
class ModelFileSpec {
  const ModelFileSpec({
    required this.fileName,
    required this.label,
    required this.kind,
  });

  /// 文件名
  final String fileName;

  /// 界面展示名称
  final String label;

  /// 用途分类
  final ModelKind kind;
}

/// 模型目录检测结果
class ModelStatus {
  const ModelStatus({
    required this.directoryPath,
    required this.presentFiles,
    this.error,
    this.isCustomPath = false,
  });

  /// 运行时模型目录（检测失败时可能为空字符串）
  final String directoryPath;

  /// 已存在且非空的模型文件名
  final List<String> presentFiles;

  /// 检测过程中的错误（null 表示检测正常）
  final String? error;

  /// 目录是否为用户自定义路径
  final bool isCustomPath;

  bool get hasError => error != null;

  /// ASR 四件套（encoder / decoder / joiner / tokens）是否齐全
  ///
  /// 不校验语种一致性：混装不同语种的模型会在加载时由引擎报错，
  /// 这里只负责「文件层面齐不齐」。
  bool get asrReady =>
      _matches('encoder') &&
      _matches('decoder') &&
      _matches('joiner') &&
      _matches('tokens');

  /// VAD 模型是否齐全（缺失时可降级到能量 VAD，不阻塞主流程）
  bool get vadReady => presentFiles.contains(ModelStorage.vadFileName);

  /// MT 权重是否存在（任意 .gguf 都算）
  bool get mtReady => presentFiles.any(ModelStorage.isMtFileName);

  /// 真实引擎可用的最小集合：ASR + MT（VAD 有能量兜底，不强制）
  bool get isReady => asrReady && mtReady;

  /// 是否存在任意可识别的 ASR 组件（用于区分「完全没装」和「装了一半」）
  bool get hasAnyAsrFile => presentFiles.any(ModelStorage.isAsrFileName);

  int get presentCount => presentFiles.length;

  /// 期望文件数：ASR 4 + MT 1（VAD 可选不计入分母，避免永远差一个）
  int get totalCount => ModelStorage.requiredFiles.length;

  /// 按角色前缀匹配文件（如 `encoder` 命中 `encoder-zh-en-int8.onnx`）
  bool _matches(String role) =>
      presentFiles.any((name) => ModelStorage.matchRole(name, role));

  /// 找出满足某角色的第一个文件名（供引擎加载用）
  String? fileForRole(String role) {
    for (final name in presentFiles) {
      if (ModelStorage.matchRole(name, role)) return name;
    }
    return null;
  }
}

/// 模型存储路径与状态检测（单例）
class ModelStorage {
  ModelStorage._();

  static final ModelStorage instance = ModelStorage._();

  /// 应用私有目录下的模型子目录名
  static const String directoryName = 'models';

  /// SharedPreferences 中保存自定义目录的键
  static const String prefsCustomPathKey = 'models.custom_directory';

  /// VAD 固定文件名（Silero 官方名，不做变体）
  static const String vadFileName = 'silero_vad.onnx';

  /// 用户自定义的模型目录（null 表示用默认私有目录）
  String? _customPath;

  /// 是否已从持久化中恢复过自定义路径
  bool _prefsLoaded = false;

  String? get customPath => _customPath;

  bool get isUsingCustomPath => _customPath != null;

  // ---------------------------------------------------------------------------
  // 角色识别规则
  // ---------------------------------------------------------------------------

  /// ASR 四件套的角色前缀
  static const List<String> asrRoles = [
    'encoder',
    'decoder',
    'joiner',
    'tokens',
  ];

  /// 判断文件名是否承担某角色
  ///
  /// 匹配规则：去掉扩展名后，以 `encoder` 等前缀开头即算命中。
  /// 这样 `encoder.onnx`（旧约定）和 `encoder-zh-en-int8.onnx`（新约定）
  /// 都能被正确识别，不需要两套逻辑。
  static bool matchRole(String fileName, String role) {
    final lower = fileName.toLowerCase();
    final dotIndex = lower.lastIndexOf('.');
    final stem = dotIndex > 0 ? lower.substring(0, dotIndex) : lower;
    if (role == 'tokens') {
      // 词表可能是 tokens.txt / tokens-zh-en.txt
      return stem == 'tokens' || stem.startsWith('tokens-');
    }
    return stem == role ||
        stem.startsWith('$role-') ||
        stem.startsWith('${role}_');
  }

  /// 是否为 ASR 相关文件
  static bool isAsrFileName(String fileName) =>
      asrRoles.any((role) => matchRole(fileName, role));

  /// 是否为 MT 权重
  static bool isMtFileName(String fileName) =>
      fileName.toLowerCase().endsWith('.gguf');

  // ---------------------------------------------------------------------------
  // 兼容用规格清单（界面展示与既有测试依赖，保持稳定）
  // ---------------------------------------------------------------------------

  static const List<String> asrFileNames = [
    'encoder.onnx',
    'decoder.onnx',
    'joiner.onnx',
    'tokens.txt',
  ];

  static const List<String> vadFileNames = [vadFileName];

  static const List<String> mtFileNames = [
    'hy-mt3-1.8b-stream-revise-q4_k_m.gguf',
    'hy-mt2-1.8b-stream-revise-q4_k_m.gguf',
  ];

  /// 模型分发通道中的代表性文件（用于说明「应有这些角色」）
  static const List<ModelFileSpec> requiredFiles = [
    ModelFileSpec(
      fileName: 'encoder.onnx',
      label: 'ASR Encoder（识别声学模型）',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'decoder.onnx',
      label: 'ASR Decoder（识别预测网络）',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'joiner.onnx',
      label: 'ASR Joiner（识别合并网络）',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'tokens.txt',
      label: 'ASR 词表',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: vadFileName,
      label: 'Silero VAD（可选，缺失则用能量检测）',
      kind: ModelKind.vad,
    ),
    ModelFileSpec(
      fileName: 'hy-mt3-1.8b-stream-revise-q4_k_m.gguf',
      label: 'Hy-MT3 流式翻译模型',
      kind: ModelKind.mt,
    ),
  ];

  // ---------------------------------------------------------------------------
  // 目录解析
  // ---------------------------------------------------------------------------

  /// 从 SharedPreferences 恢复自定义目录（幂等，可重复调用）
  Future<void> loadPreferences() async {
    if (_prefsLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(prefsCustomPathKey);
      if (saved != null && saved.trim().isNotEmpty) {
        _customPath = saved;
      }
      _prefsLoaded = true;
    } catch (_) {
      // 测试环境 / 插件不可用：保持默认目录，不抛异常
    }
  }

  /// 设置自定义模型目录
  ///
  /// [path] 为 null 或空字符串时恢复默认私有目录。
  /// 只做持久化，不校验目录是否存在（目录可能之后才创建）。
  Future<void> setCustomDirectory(String? path) async {
    final normalized =
        (path == null || path.trim().isEmpty) ? null : path.trim();
    _customPath = normalized;
    _prefsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized == null) {
        await prefs.remove(prefsCustomPathKey);
      } else {
        await prefs.setString(prefsCustomPathKey, normalized);
      }
    } catch (_) {
      // 持久化失败不影响本次运行期的设置
    }
  }

  /// 解析运行时模型目录（不创建）
  Future<Directory> resolveDirectory() async {
    await loadPreferences();
    final custom = _customPath;
    if (custom != null) {
      return Directory(custom);
    }
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}$directoryName');
  }

  /// 确保模型目录存在（自定义路径会一并创建）
  Future<Directory> ensureDirectory() async {
    final dir = await resolveDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // ---------------------------------------------------------------------------
  // 检测
  // ---------------------------------------------------------------------------

  /// 检测模型文件是否齐全
  ///
  /// 只认「存在且非空」的文件，空文件视为缺失（避免下载中断留下空壳）。
  Future<ModelStatus> inspect() async {
    final Directory dir;
    try {
      dir = await resolveDirectory();
    } catch (e) {
      // 测试环境 / 平台通道不可用时走这里，由 UI 展示「无法检测」
      return ModelStatus(
        directoryPath: '',
        presentFiles: const [],
        error: e.toString(),
        isCustomPath: _customPath != null,
      );
    }

    final present = <String>[];
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('.')) continue;
          final lower = name.toLowerCase();
          final relevant =
              isAsrFileName(name) || isMtFileName(name) || lower == vadFileName;
          if (!relevant) continue;
          try {
            final length = await entity.length();
            if (length > 0) present.add(name);
          } on FileSystemException {
            // 单个文件读取失败不影响整体检测
          }
        }
      }
    } on FileSystemException catch (e) {
      return ModelStatus(
        directoryPath: dir.path,
        presentFiles: present,
        error: e.toString(),
        isCustomPath: _customPath != null,
      );
    }

    present.sort();
    return ModelStatus(
      directoryPath: dir.path,
      presentFiles: present,
      isCustomPath: _customPath != null,
    );
  }

  /// 在模型目录中按角色查找文件并返回绝对路径
  ///
  /// 供推理引擎拼装模型参数；找不到返回 null，由引擎决定降级。
  Future<String?> resolveFileForRole(String role) async {
    final status = await inspect();
    if (status.hasError) return null;
    final name = status.fileForRole(role);
    if (name == null) return null;
    return '${status.directoryPath}${Platform.pathSeparator}$name';
  }

  /// 查找 VAD 模型绝对路径
  Future<String?> resolveVadModelPath() async {
    final status = await inspect();
    if (status.hasError || !status.vadReady) return null;
    return '${status.directoryPath}${Platform.pathSeparator}$vadFileName';
  }

  /// 查找 MT 权重绝对路径
  Future<String?> resolveMtModelPath() async {
    final status = await inspect();
    if (status.hasError) return null;
    for (final name in status.presentFiles) {
      if (isMtFileName(name)) {
        return '${status.directoryPath}${Platform.pathSeparator}$name';
      }
    }
    return null;
  }
}