/// VAD 公共类型定义
/// 供 isolate 内外共用：配置、状态、事件、后端标识。
/// 刻意保持"纯 Dart"（不 import flutter / ffi），以便安全跨 isolate 传递并在单元测试中直接使用。
library live_translate.core.audio.vad.vad_types;

import 'dart:typed_data';

/// VAD 后端类型
enum VadBackend {
  /// Silero ONNX 模型（sherpa-onnx，需模型文件）
  silero,

  /// 自适应能量 VAD（无模型时的兜底，纯 Dart）
  energy,
}

/// VAD 状态
enum VadState {
  /// 空闲，等待语音开始
  idle,

  /// 语音中
  speaking,

  /// 尾部静音，等待确认语音结束
  trailing,
}

/// VadState 与 isolate 消息之间的字符串映射（跨 isolate 只能传原始类型，避免依赖对象序列化）
String vadStateToWire(VadState state) {
  switch (state) {
    case VadState.idle:
      return 'idle';
    case VadState.speaking:
      return 'speaking';
    case VadState.trailing:
      return 'trailing';
  }
}

VadState vadStateFromWire(String value) {
  switch (value) {
    case 'speaking':
      return VadState.speaking;
    case 'trailing':
      return VadState.trailing;
    case 'idle':
    default:
      return VadState.idle;
  }
}

String vadBackendToWire(VadBackend backend) {
  switch (backend) {
    case VadBackend.silero:
      return 'silero';
    case VadBackend.energy:
      return 'energy';
  }
}

VadBackend vadBackendFromWire(String value) {
  switch (value) {
    case 'silero':
      return VadBackend.silero;
    case 'energy':
    default:
      return VadBackend.energy;
  }
}

/// VAD 处理器配置
class VadConfig {
  /// 采样率 (Hz)
  final int sampleRate;

  /// 帧长度 (ms)
  final int frameDurationMs;

  /// 绝对能量阈值（RMS，能量 VAD 使用）
  ///
  /// 注意：此处阈值基于"已符号扩展的正确 int16 RMS"，取值 0~1。
  /// 正常语音 RMS 约 0.02 ~ 0.2，静音底噪约 0.001 ~ 0.01。
  final double energyThreshold;

  /// 自适应噪声底倍数：有效阈值 = max(energyThreshold, noiseFloor * 本倍数)
  final double noiseFloorMultiplier;

  /// 滞回比：判定语音结束时阈值下浮比例（避免阈值附近抖动反复切状态）
  final double hysteresisRatio;

  /// 噪声底自适应速度（0~1，越大跟随越快；仅在空闲态更新）
  final double noiseFloorAdaptRate;

  /// 静音帧容忍数（连续多少静音帧判定语音结束）
  final int silenceFrameTolerance;

  /// 最小语音帧数（最少多少帧才算有效语音段）
  final int minSpeechFrames;

  /// 最大缓冲帧数（防止内存溢出 / 长句无限增长）
  final int maxBufferFrames;

  /// 是否优先尝试 Silero VAD（模型可用时）
  final bool preferSilero;

  /// Silero 模型路径（null 表示未提供，将直接走能量 VAD）
  final String? sileroModelPath;

  /// Silero 判定阈值
  final double sileroThreshold;

  /// Silero 最短静音时长 (s)，超过即切分
  final double sileroMinSilenceDuration;

  /// Silero 最短语音时长 (s)，低于此不算语音
  final double sileroMinSpeechDuration;

  /// Silero 单段最长时长 (s)，超过强制切分
  final double sileroMaxSpeechDuration;

  const VadConfig({
    this.sampleRate = 16000,
    this.frameDurationMs = 30,
    this.energyThreshold = 0.02,
    this.noiseFloorMultiplier = 3.0,
    this.hysteresisRatio = 0.6,
    this.noiseFloorAdaptRate = 0.05,
    this.silenceFrameTolerance = 10,
    this.minSpeechFrames = 3,
    this.maxBufferFrames = 300, // 约 9 秒 @ 30ms/帧
    this.preferSilero = true,
    this.sileroModelPath,
    this.sileroThreshold = 0.5,
    this.sileroMinSilenceDuration = 0.25,
    this.sileroMinSpeechDuration = 0.25,
    this.sileroMaxSpeechDuration = 8.0,
  });

  /// 每帧的采样点数
  int get samplesPerFrame => (sampleRate * frameDurationMs / 1000).round();

  /// 每帧的字节数 (16bit = 2 bytes)
  int get bytesPerFrame => samplesPerFrame * 2;

  /// 语音结束所需静音时长 (ms)
  int get silenceHangoverMs => silenceFrameTolerance * frameDurationMs;

  VadConfig copyWith({
    int? sampleRate,
    int? frameDurationMs,
    double? energyThreshold,
    double? noiseFloorMultiplier,
    double? hysteresisRatio,
    double? noiseFloorAdaptRate,
    int? silenceFrameTolerance,
    int? minSpeechFrames,
    int? maxBufferFrames,
    bool? preferSilero,
    String? sileroModelPath,
    double? sileroThreshold,
    double? sileroMinSilenceDuration,
    double? sileroMinSpeechDuration,
    double? sileroMaxSpeechDuration,
  }) {
    return VadConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      frameDurationMs: frameDurationMs ?? this.frameDurationMs,
      energyThreshold: energyThreshold ?? this.energyThreshold,
      noiseFloorMultiplier: noiseFloorMultiplier ?? this.noiseFloorMultiplier,
      hysteresisRatio: hysteresisRatio ?? this.hysteresisRatio,
      noiseFloorAdaptRate: noiseFloorAdaptRate ?? this.noiseFloorAdaptRate,
      silenceFrameTolerance:
          silenceFrameTolerance ?? this.silenceFrameTolerance,
      minSpeechFrames: minSpeechFrames ?? this.minSpeechFrames,
      maxBufferFrames: maxBufferFrames ?? this.maxBufferFrames,
      preferSilero: preferSilero ?? this.preferSilero,
      sileroModelPath: sileroModelPath ?? this.sileroModelPath,
      sileroThreshold: sileroThreshold ?? this.sileroThreshold,
      sileroMinSilenceDuration:
          sileroMinSilenceDuration ?? this.sileroMinSilenceDuration,
      sileroMinSpeechDuration:
          sileroMinSpeechDuration ?? this.sileroMinSpeechDuration,
      sileroMaxSpeechDuration:
          sileroMaxSpeechDuration ?? this.sileroMaxSpeechDuration,
    );
  }

  @override
  String toString() =>
      'VadConfig($sampleRate Hz, $frameDurationMs ms/帧, '
      'th=$energyThreshold, floorX=$noiseFloorMultiplier, '
      'hangover=$silenceFrameTolerance 帧, silero=$preferSilero)';
}

/// 一段检测出的语音（16bit 单声道 PCM 小端）
class VadSegment {
  /// PCM 字节数据
  final Uint8List pcm;

  /// 段内有效语音帧数
  final int speechFrames;

  /// 段内总帧数（含头尾静音）
  final int totalFrames;

  /// 采样率
  final int sampleRate;

  const VadSegment({
    required this.pcm,
    required this.speechFrames,
    required this.totalFrames,
    required this.sampleRate,
  });

  /// 段时长（按实际 PCM 采样数 / 采样率换算）
  Duration get duration {
    if (sampleRate <= 0 || pcm.isEmpty) return Duration.zero;
    final samples = pcm.length ~/ 2;
    return Duration(milliseconds: (samples * 1000 / sampleRate).round());
  }

  /// 有效语音时长（按语音帧数换算）
  Duration get speechDuration {
    if (sampleRate <= 0 || totalFrames <= 0) return Duration.zero;
    final msPerFrame = duration.inMilliseconds / totalFrames;
    return Duration(milliseconds: (speechFrames * msPerFrame).round());
  }

  @override
  String toString() =>
      'VadSegment(${pcm.length} bytes, speech=$speechFrames/$totalFrames 帧, ${sampleRate}Hz)';
}

/// VAD 事件：状态变化
class VadStateChangedEvent {
  final VadState previous;
  final VadState current;

  const VadStateChangedEvent({required this.previous, required this.current});

  @override
  String toString() => 'VadStateChanged($previous -> $current)';
}

/// VAD 事件：语音段就绪
class VadSegmentReadyEvent {
  final VadSegment segment;

  const VadSegmentReadyEvent(this.segment);

  @override
  String toString() => 'VadSegmentReady(${segment.pcm.length} bytes)';
}