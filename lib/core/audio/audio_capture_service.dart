/// 音频捕获服务
///
/// 职责：拿系统内录 PCM → 丢给 VAD isolate → 收到语音段 → 回调给 ASR。
///
/// 本版关键变化：
/// 1. **不再依赖 `system_audio_recorder` 插件**（0.0.1 版在 Android 14 上必崩，
///    详见下方说明），改用本项目自研的 `AudioCaptureService.kt`
///    + MethodChannel / EventChannel。
/// 2. **VAD 全部搬进 isolate**（`vad_isolate_worker`），主线程不再算 RMS / 拼缓冲。
/// 3. 默认优先 **Silero VAD**（复用已声明依赖 sherpa_onnx，不新增插件），
///    加载失败或未配置模型时自动降级到**自适应能量 VAD**。
/// 4. 修掉了旧实现的 int16 符号扩展 bug（负样本被当正数，RMS 虚高 → 持续误触发）。
/// 5. `stop()` 会 `flush()` 吐出最后一段，不会把用户刚说完的话丢掉。
/// 6. `dispose()` 干净释放 isolate / 端口 / 流订阅（钢印级资源释放要求）。
///
/// ### 为什么弃用 system_audio_recorder 0.0.1
///
/// 该插件在 Android 14+ 有多处致命缺陷，导致用户点「录制整个屏幕」后**闪退**：
/// - `ForegroundService` 未在插件清单声明（只写在 example 里），
///   `startForegroundService()` 直接抛异常并被吞掉；
/// - `ActivityCompat.requestPermissions(this as Activity, ...)` ——
///   `this` 是 Service，必然 `ClassCastException`；
/// - 前台通知未调用 `setSmallIcon()`，`startForeground()` 抛 "Invalid notification"；
/// - 清单缺 `foregroundServiceType`，Android 14 抛
///   `MissingForegroundServiceTypeException`；
/// - 以上异常全被 `try/catch` 吞掉 → 前台服务从未真正启动 →
///   `getMediaProjection()` 抛 `SecurityException` → **进程崩溃**。
///
/// 因此改为自研实现：严格按「先 `startForeground(TYPE_MEDIA_PROJECTION)`
/// 再 `getMediaProjection()`」的顺序。
library live_translate.core.audio.audio_capture_service;

import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';

import 'vad/vad_service.dart';
import 'vad/vad_types.dart';

// 兼容旧导入路径：老代码可从本文件 import VadConfig / VadState
export 'vad/vad_types.dart' show VadBackend, VadSegment, VadState, VadConfig;

/// 音频捕获服务（单例）
class AudioCaptureService {
  static final AudioCaptureService _instance = AudioCaptureService._internal();
  factory AudioCaptureService() => _instance;
  AudioCaptureService._internal();

  /// 原生内录控制通道（自研 AudioCaptureService.kt）
  static const MethodChannel _controlChannel =
      MethodChannel('live_translate/audio_capture');

  /// 原生 PCM 数据流通道（20ms 一块，PCM16 单声道）
  static const EventChannel _audioStreamChannel =
      EventChannel('live_translate/audio_stream');

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
  ///
  /// 注意：这里**不会**请求屏幕录制授权。授权由 [start] 在用户点击开始后触发，
  /// 避免「一打开应用就弹录制选择框」。
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

    // 屏幕录制授权推迟到 start() 中按需请求
    log(
      '[AudioCapture] 初始化完成: ${_config.sampleRate}Hz, '
      '${_config.frameDurationMs}ms/帧, VAD=${_vad.backend}',
      name: 'AudioCapture',
    );
  }

  /// 开始捕获系统音频
  ///
  /// 用户主动触发；先弹屏幕录制授权框，授权成功后才启动前台服务。
  Future<void> start() async {
    if (_isRecording || _isStarting) return;
    _isStarting = true;

    try {
      // 1) 请求屏幕录制（系统内录）授权 —— 必须由用户手动确认
      final granted = await _requestProjection();
      if (!granted) {
        throw StateError('未获得屏幕录制授权');
      }

      // 2) 启动前台服务并开始采集
      final started = await _controlChannel.invokeMethod<bool>(
        'startCapture',
        {'sampleRate': _config.sampleRate},
      );

      if (started != true) {
        throw StateError('启动系统录音失败');
      }

      _isRecording = true;
      _vad.reset();

      // 3) 监听 PCM 数据流
      _audioSubscription ??= _audioStreamChannel.receiveBroadcastStream().listen(
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

  /// 请求屏幕录制授权（系统弹窗由 MainActivity 处理）
  Future<bool> _requestProjection() async {
    try {
      final granted =
          await _controlChannel.invokeMethod<bool>('requestProjection');
      return granted == true;
    } on PlatformException catch (e) {
      log('[AudioCapture] 请求屏幕录制授权失败: $e', name: 'AudioCapture');
      return false;
    } on MissingPluginException {
      log('[AudioCapture] 原生内录通道不可用（非 Android 平台？）',
          name: 'AudioCapture');
      return false;
    }
  }

  /// 接收音频数据（从 EventChannel）
  ///
  /// 直接转给 VAD isolate，主线程零计算。
  void _onAudioDataReceived(dynamic data) {
    if (!_isRecording || data == null) return;
    final Uint8List? pcm = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : null);
    if (pcm == null || pcm.isEmpty) return;
    _vad.feed(pcm);
  }

  /// 停止捕获
  Future<void> stop() async {
    if (!_isRecording) return;

    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;

      await _controlChannel.invokeMethod<bool>('stopCapture');

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