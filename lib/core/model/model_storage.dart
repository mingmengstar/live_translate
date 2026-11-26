/// 模型文件存储与就绪状态检测
///
/// 模型下载 / 导入管线的第一块地基：
/// - 统一约定运行时模型目录（应用私有目录下的 `models/`）
/// - 统一列出必需文件，供首页状态卡片与导入说明页复用
/// - 当前只做「存在且非空」检查；SHA256 校验在后续下载管线中实现
library live_translate.core.model.model_storage;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 模型用途分类
enum ModelKind { asr, vad, mt }

/// 单个模型文件描述
class ModelFileSpec {
  const ModelFileSpec({
    required this.fileName,
    required this.label,
    required this.kind,
  });

  /// 文件名（与模型分发通道中的文件名保持一致）
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
  });

  /// 运行时模型目录（检测失败时可能为空字符串）
  final String directoryPath;

  /// 已存在且非空的模型文件名
  final List<String> presentFiles;

  /// 检测过程中的错误（null 表示检测正常）
  final String? error;

  bool get hasError => error != null;

  bool _hasAll(Iterable<String> names) => names.every(presentFiles.contains);

  /// ASR 模型是否齐全
  bool get asrReady => _hasAll(ModelStorage.asrFileNames);

  /// VAD 模型是否齐全（缺失时可降级到能量 VAD）
  bool get vadReady => _hasAll(ModelStorage.vadFileNames);

  /// MT 模型是否齐全
  bool get mtReady => _hasAll(ModelStorage.mtFileNames);

  /// 真实引擎可用的最小集合：ASR + MT（VAD 有能量兜底，不强制）
  bool get isReady => asrReady && mtReady;

  int get presentCount => presentFiles.length;

  int get totalCount => ModelStorage.requiredFiles.length;
}

/// 模型存储路径与状态检测（单例）
class ModelStorage {
  ModelStorage._();

  static final ModelStorage instance = ModelStorage._();

  /// 应用私有目录下的模型子目录名
  static const String directoryName = 'models';

  static const List<String> asrFileNames = [
    'encoder.onnx',
    'decoder.onnx',
    'joiner.onnx',
    'tokens.txt',
  ];

  static const List<String> vadFileNames = ['silero_vad.onnx'];

  static const List<String> mtFileNames = ['hy-mt1.5-q4_k_m.gguf'];

  /// 模型分发通道（GitHub Release v1.0.0-models）中的全部文件
  static const List<ModelFileSpec> requiredFiles = [
    ModelFileSpec(
      fileName: 'encoder.onnx',
      label: 'ASR Encoder',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'decoder.onnx',
      label: 'ASR Decoder',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'joiner.onnx',
      label: 'ASR Joiner',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'tokens.txt',
      label: 'ASR 词表',
      kind: ModelKind.asr,
    ),
    ModelFileSpec(
      fileName: 'silero_vad.onnx',
      label: 'Silero VAD（可选）',
      kind: ModelKind.vad,
    ),
    ModelFileSpec(
      fileName: 'hy-mt1.5-q4_k_m.gguf',
      label: 'Hy-MT1.5 翻译模型',
      kind: ModelKind.mt,
    ),
  ];

  /// 解析运行时模型目录（不创建）
  Future<Directory> resolveDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}$directoryName');
  }

  /// 确保模型目录存在
  Future<Directory> ensureDirectory() async {
    final dir = await resolveDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 检测模型文件是否齐全
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
      );
    }

    final present = <String>[];
    try {
      if (await dir.exists()) {
        for (final spec in requiredFiles) {
          final file =
              File('${dir.path}${Platform.pathSeparator}${spec.fileName}');
          try {
            if (await file.exists()) {
              final length = await file.length();
              if (length > 0) {
                present.add(spec.fileName);
              }
            }
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
      );
    }

    return ModelStatus(
      directoryPath: dir.path,
      presentFiles: present,
    );
  }
}
