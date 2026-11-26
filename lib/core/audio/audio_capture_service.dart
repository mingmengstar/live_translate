/// 音频捕获服务
///
/// 职责：拿系统内录 PCM → 丢给 VAD isolate → 收到语音段 → 回调给 ASR。
///
/// 相比上一版的关键变化：
/// 1. **VAD 全部搬进 isolate**（`vad_isolate_worker`），主线程不再算 RMS / 拼缓冲。
/// 2. 默认优先 **Silero VAD**（复用已声明依赖 sherpa_onnx，不新增插件），
///    加载失败或未配置模型时自动降级到**自适应能量 VAD**。
/// 3. 修掉了旧实现的 int16 符号扩展 bug（负样本被当正数，RMS 虚高 → 持续误触发）。
/// 4. `stop()` 会 `flush()` 吐出最后一段，不会把用户刚说完的话丢掉。
/// 5. `dispose()` 干净释放 isolate / 端口 / 流订阅（钢印级资源释放要求）。
library live_translate.core.audio.audio_capture_service;

import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:system_audio_recorder/system_audio_recorder.dart';

import 'vad/vad_service.dart';
import 'vad/vad_types.dart';

// 兼容旧导入路径：老代码可从本文件 import VadConfig / VadState
export 'vad/vad_types.dart' show VadBackend, VadSegment, VadState, VadConfig;

/// 音频捕获服务（单例）
class AudioCaptureService {
  static final AudioCaptureService _instance = AudioCaptureService._internal();
  factory AudioCaptureService() => _instance;
  AudioCaptureService._internal();

  // 配置
  VadConfig _config = const VadConfig();

  // 状态
  bool _isRecording = false;
  bool _isStarting = false;

  // VAD 子服务
  final VadService _vad = VadService();

  // 回调
  Function(Uint8List)? _onAudioSegment;

  // 音频流订阅
  StreamSubscription<dynamic>? _audioSubscription;

  /// 是否正在录音
  bool get isRecording => _isRecording;

  /// 当前 VAD 状态
  VadState get vadState => _vad.state;

  /// 当前 VAD 后端（Silero / 能量）
  VadBackend get vadBackend => _vad.backend;

  /// VAD 后端说明（UI 可展示当前用的是哪种 VAD）
  String? get vadBackendNote => _vad.backendNote;

  /// 当前配置
  VadConfig get config => _config;

  /// 初始化音频捕获服务
  ///
  /// [sileroModelPath] 提供时优先使用 Silero VAD；为 null 则用能量 VAD。
  Future<void> initialize({
    VadConfig? config,
    String? sileroModelPath,
    required Function(Uint8List) onAudioSegment,
  }) async {
    _config = (config ?? const VadConfig()).copyWith(
      sileroModelPath: sileroModelPath ?? config?.sileroModelPath,
    );
    _onAudioSegment = onAudioSegment;

    // 启动 VAD isolate（失败不抛异常，降级继续）
    final ready = await _vad.start(
      config: _config,
      callbacks: VadCallbacks(
        onReady: (backend, note) {
          log('[AudioCapture] VAD 就绪: $backend ($note)', name: 'AudioCapture');
        },
        onSegment: (segment) {
          if (_isRecording) {
            _onAudioSegment?.call(segment.pcm);
          }
        },
        onError: (message) {
          log('[AudioCapture] VAD 警告: $message', name: 'AudioCapture');
        },
      ),
    );

    if (!ready) {
      log('[AudioCapture] VAD isolate 未就绪，语音段将不可用', name: 'AudioCapture');
    }

    // 请求录音权限（放在 VAD 之后，避免权限弹窗期间 VAD 启动超时）
    final granted = await SystemAudioRecorder.requestRecord(
      titleNotification: '实时翻译',
      messageNotification: '正在录制系统音频用于翻译',
    );
    if (!granted) {
      throw StateError('录音权限被拒绝');
    }

    log(
      '[AudioCapture] 初始化完成: ${_config.sampleRate}Hz, '
      '${_config.frameDurationMs}ms/帧, VAD=${_vad.backend}',
      name: 'AudioCapture',
    );
  }

  /// 开始捕获系统音频
  Future<void> start() async {
    if (_isRecording || _isStarting) return;
    _isStarting = true;

    try {
      // 启动系统内录 (16kHz, 单声道, 16bit PCM)
      final started = await SystemAudioRecorder.startRecord(
        sampleRate: _config.sampleRate,
        bufferSize: _config.samplesPerFrame,
        toStream: true,
        toFile: false,
      );

      if (!started) {
        throw StateError('启动系统录音失败');
      }

      _isRecording = true;
      _vad.reset();

      // 监听音频流（EventChannel）
      _audioSubscription ??= SystemAudioRecorder.audioStream
          .receiveBroadcastStream()
          .map((dynamic data) => data as List<int>)
          .listen(
            _onAudioDataReceived,
            onError: (Object error) {
              log('[AudioCapture] 音频流错误: $error', name: 'AudioCapture');
            },
            onDone: () {
              log('[AudioCapture] 音频流结束', name: 'AudioCapture');
            },
          );

      log('[AudioCapture] 开始捕获系统音频', name: 'AudioCapture');
    } catch (e, stack) {
      _isRecording = false;
      log('[AudioCapture] 启动失败: $e\n$stack', name: 'AudioCapture');
      rethrow;
    } finally {
      _isStarting = false;
    }
  }

  /// 接收音频数据（从 EventChannel）
  ///
  /// 直接转给 VAD isolate，主线程零计算。
  void _onAudioDataReceived(List<int> data) {
    if (!_isRecording || data.isEmpty) return;
    _vad.feed(Uint8List.fromList(data));
  }

  /// 停止捕获
  Future<void> stop() async {
    if (!_isRecording) return;

    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;

      await SystemAudioRecorder.stopRecord();

      // 吐出缓冲区中残留的语音段（避免丢掉用户最后一句）
      _vad.flush();

      _isRecording = false;

      log('[AudioCapture] 停止捕获', name: 'AudioCapture');
    } catch (e, stack) {
      log('[AudioCapture] 停止失败: $e\n$stack', name: 'AudioCapture');
    }
  }

  /// 释放资源（钢印级：必须彻底释放）
  Future<void> dispose() async {
    await stop();
    await _vad.dispose();
    _onAudioSegment = null;
  }
}