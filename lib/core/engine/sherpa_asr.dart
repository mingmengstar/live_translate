/// Sherpa-ONNX 流式 ASR 引擎
///
/// 真实离线语音识别，基于 `sherpa_onnx 2.0.3` 的 OnlineRecognizer
/// （zipformer2 transducer 结构）。
///
/// 设计要点（对应钢印级约束）：
/// 1. **推理在独立 Isolate**：本文件只做「投递字节 / 接收文本」，
///    原生 ONNX 前向全在 [sherpaAsrWorkerEntry] 里跑，绝不阻塞 UI。
/// 2. **失败自动降级**：模型缺失 / 加载失败时 `initialize()` 抛异常，
///    由 `EngineManager.switchASREngine()` 捕获并把当前引擎置空，
///    上层再切回 `MockASR`（见 `TranslationService.initialize`）。
/// 3. **资源彻底释放**：`dispose()` 先 `flush` 再 `dispose` 再 `kill`，
///    原生 recognizer / stream 在 worker 内 free。
///
/// 与 VAD 的分工：
/// - VAD 负责「哪一段是语音」，产出 `VadSegment.pcm`
/// - 本引擎负责「这段语音说的是什么」，产出 `ASRResult`
/// 两者通过 `TranslationService._onAudioSegment` 串联。
library live_translate.core.engine.sherpa_asr;

import 'dart:async';
import 'dart:developer';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:live_translate/core/model/model_storage.dart';

import 'asr_engine.dart';
import 'sherpa_asr_worker.dart';

/// Sherpa-ONNX 流式识别引擎
class SherpaASREngine implements ASREngine {
  /// 引擎稳定标识（持久化 / UI 选项用）
  static const String kEngineId = 'sherpa_asr';

  @override
  String get engineId => kEngineId;

  @override
  String get displayName => 'Sherpa-ONNX 本地识别';

  @override
  bool isInitialized = false;

  @override
  bool isRunning = false;

  @override
  String currentLanguage = 'en';

  /// 模型本身是多语种联合训练的，这里列的是「可以切」的语言代码。
  /// 注意：单套 zipformer 模型不能真的切语种，切换只是记录意图，
  /// 真正换语种需要下载对应语言包（见 `ModelCatalog.asrFilesFor`）。
  @override
  final List<String> supportedLanguages = [
    'en',
    'zh',
    'ja',
    'ko',
    'ru',
    'th',
    'vi',
    'ar',
    'id',
  ];

  // ---------------------------------------------------------------------------
  // Isolate 基础设施
  // ---------------------------------------------------------------------------

  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _hostPort;
  StreamSubscription<dynamic>? _sub;

  /// 模型加载是否成功（worker 回了 ready:true）
  bool _modelReady = false;

  /// 最近一次错误说明（UI 可展示，便于排查「为什么没出字」）
  String? _lastError;

  /// worker 侧就绪说明（如「Sherpa-ONNX zipformer2 已加载 (threads=2)」）
  String? _backendNote;

  /// 回调（start() 时绑定）
  Function(ASRResult)? _onResult;
  Function(Object error, StackTrace stack)? _onError;

  /// 已投递的音频字节数（诊断用）
  int _pushedBytes = 0;

  /// 模型路径（initialize 时解析）
  String? _encoderPath;
  String? _decoderPath;
  String? _joinerPath;
  String? _tokensPath;

  // 获取器
  bool get isModelReady => _modelReady;

  String? get lastError => _lastError;

  String? get backendNote => _backendNote;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 初始化：解析模型路径 → 启动 isolate → 加载模型
  ///
  /// 抛异常表示「无法使用真实引擎」，由调用方降级回 Mock。
  /// 常见原因：模型未下载、路径不完整、原生库缺失、ABI 不匹配。
  @override
  Future<void> initialize({
    String? modelPath,
    String language = 'en',
    Map<String, dynamic> config = const {},
  }) async {
    currentLanguage = language;

    // 1) 解析四件套路径（允许 config 显式覆盖，便于测试 / 指定语言包）
    _encoderPath = (config['encoderPath'] as String?) ??
        await ModelStorage.instance.resolveFileForRole('encoder');
    _decoderPath = (config['decoderPath'] as String?) ??
        await ModelStorage.instance.resolveFileForRole('decoder');
    _joinerPath = (config['joinerPath'] as String?) ??
        await ModelStorage.instance.resolveFileForRole('joiner');
    _tokensPath = (config['tokensPath'] as String?) ??
        await ModelStorage.instance.resolveFileForRole('tokens');

    final missing = <String>[
      if (_encoderPath == null) 'encoder',
      if (_decoderPath == null) 'decoder',
      if (_joinerPath == null) 'joiner',
      if (_tokensPath == null) 'tokens',
    ];
    if (missing.isNotEmpty) {
      _lastError = '缺少模型文件：${missing.join(' / ')}';
      throw StateError(_lastError!);
    }

    // 2) 起 isolate 并等待 ready
    final ready = await _spawnWorker(
      numThreads: (config['numThreads'] as num?)?.toInt() ?? 2,
    );
    if (!ready) {
      throw StateError(_lastError ?? 'Sherpa-ONNX 模型加载失败');
    }

    isInitialized = true;
    log(
      '[SherpaASR] 初始化完成: lang=$language, note=$_backendNote',
      name: 'SherpaASR',
    );
  }

  /// 启动 isolate 并投递 init，等待 ready 消息
  Future<bool> _spawnWorker({required int numThreads}) async {
    final hostPort = ReceivePort();
    final completer = Completer<bool>();

    // 兜底超时：大模型（~200MB）冷加载在低端机上可能很慢，
    // 但也不能无限等，否则 UI 会一直转圈。
    final timeout = Timer(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        _lastError = '模型加载超时（60s）';
        completer.complete(false);
      }
    });

    try {
      _isolate = await Isolate.spawn(
        sherpaAsrWorkerEntry,
        hostPort.sendPort,
        debugName: 'sherpa-asr-worker',
        errorsAreFatal: false,
      );
      _hostPort = hostPort;

      _sub = hostPort.listen(
        (Object? raw) {
          if (raw is! Map) return;
          final msg = raw.cast<String, Object?>();
          final type = msg['type'] as String?;

          switch (type) {
            case 'handshake':
              final port = msg['port'];
              if (port is SendPort) {
                _workerPort = port;
                port.send({
                  'type': 'init',
                  'encoder': _encoderPath,
                  'decoder': _decoderPath,
                  'joiner': _joinerPath,
                  'tokens': _tokensPath,
                  'numThreads': numThreads,
                });
              }
              break;

            case 'ready':
              _modelReady = (msg['ok'] as bool?) ?? false;
              _backendNote = msg['note'] as String?;
              if (!_modelReady) {
                _lastError = _backendNote ?? '模型加载失败';
              }
              if (!completer.isCompleted) completer.complete(_modelReady);
              break;

            case 'result':
              final text = (msg['text'] as String?)?.trim() ?? '';
              if (text.isEmpty) break;
              _onResult?.call(
                ASRResult(
                  text: text,
                  isFinal: (msg['isFinal'] as bool?) ?? false,
                  confidence: 1.0,
                  // sherpa 的 result 不带时间戳；用「已投递音频字节数」
                  // 折算成会话内相对时间（16kHz × 16bit = 32000 B/s）
                  timestamp: Duration(
                    milliseconds: _pushedBytes * 1000 ~/ 32000,
                  ),
                  language: currentLanguage,
                ),
              );
              break;

            case 'error':
              final message = msg['message'] as String? ?? '未知 ASR 错误';
              _lastError = message;
              log('[SherpaASR] worker 错误: $message', name: 'SherpaASR');
              _onError?.call(StateError(message), StackTrace.current);
              break;

            case 'done':
              break;

            default:
              break;
          }
        },
        onError: (Object e) {
          _lastError = 'ASR worker 通信异常: $e';
          _onError?.call(e, StackTrace.current);
        },
      );

      return await completer.future;
    } catch (e, s) {
      _lastError = 'ASR isolate 启动失败: $e';
      log('[SherpaASR] 启动失败: $e\n$s', name: 'SherpaASR');
      await _teardown();
      return false;
    } finally {
      timeout.cancel();
    }
  }

  @override
  Future<void> start({
    required Function(ASRResult) onResult,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    if (!isInitialized) {
      throw StateError('SherpaASR 未初始化');
    }
    _onResult = onResult;
    _onError = onError;
    isRunning = true;
    _pushedBytes = 0;
    log('[SherpaASR] 开始识别', name: 'SherpaASR');
  }

  @override
  Future<void> stop() async {
    if (!isRunning) return;
    isRunning = false;

    // 通知 worker 吐出尾包，并给一点时间把最后一句回传上来
    final port = _workerPort;
    if (port != null) {
      try {
        port.send({'type': 'flush'});
        await Future<void>.delayed(const Duration(milliseconds: 120));
      } catch (_) {
        // 忽略
      }
    }
    log(
      '[SherpaASR] 停止识别（累计投递 $_pushedBytes 字节）',
      name: 'SherpaASR',
    );
  }

  /// 推送 PCM16 单声道 16kHz 音频
  ///
  /// 非阻塞：只做一次 send，worker 侧负责解码。
  @override
  Future<void> pushAudio(List<int> audioData) async {
    if (!isRunning) return;
    final port = _workerPort;
    if (port == null || audioData.isEmpty) return;

    try {
      final pcm = audioData is Uint8List
          ? audioData
          : Uint8List.fromList(audioData);
      _pushedBytes += pcm.length;
      port.send({'type': 'feed', 'pcm': pcm});
    } catch (e) {
      _lastError = '推送音频失败: $e';
      log('[SherpaASR] pushAudio 失败: $e', name: 'SherpaASR');
    }
  }

  /// 切换语言
  ///
  /// 单套 zipformer 模型不支持真正切语种，这里只记录意图。
  /// 要真的换语种，需要下载对应语言包并重新 initialize。
  @override
  Future<void> switchLanguage(String language) async {
    if (!supportedLanguages.contains(language)) {
      throw ArgumentError('不支持的语言: $language');
    }
    currentLanguage = language;
    log(
      '[SherpaASR] 语言标记切换为 $language（需重新加载对应语言包才真正生效）',
      name: 'SherpaASR',
    );
  }

  @override
  Future<void> dispose() async {
    isRunning = false;
    isInitialized = false;
    _modelReady = false;
    _onResult = null;
    _onError = null;
    await _teardown();
    log('[SherpaASR] 已释放', name: 'SherpaASR');
  }

  /// 彻底释放 isolate / 端口 / 原生资源
  Future<void> _teardown() async {
    final port = _workerPort;
    if (port != null) {
      try {
        port.send({'type': 'dispose'});
      } catch (_) {
        // 忽略
      }
      // 给 worker 时间 free() 原生 recognizer / stream
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }

    await _sub?.cancel();
    _sub = null;
    _hostPort?.close();
    _hostPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
    _backendNote = null;
  }

  @override
  Map<String, dynamic> getStatus() {
    return {
      'engineId': engineId,
      'displayName': displayName,
      'isInitialized': isInitialized,
      'isRunning': isRunning,
      'modelReady': _modelReady,
      'language': currentLanguage,
      'pushedBytes': _pushedBytes,
      'note': _backendNote,
      'error': _lastError,
    };
  }
}