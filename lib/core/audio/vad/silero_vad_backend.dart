/// Silero VAD 后端（基于已声明的 sherpa_onnx，无新增插件）
///
/// 只在 isolate 内使用：sherpa_onnx 的 FFI 绑定是 per-isolate 的，
/// worker 必须在自己的 isolate 里调用 initBindings()。
///
/// 语义说明：Silero 自带分段（minSilenceDuration / maxSpeechDuration），
/// 因此走模型时直接采用它产出的语音段，不再叠加 VadSegmenter，
/// 避免两套切分规则互相打架。
library live_translate.core.audio.vad.silero_vad_backend;

import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'vad_types.dart';

/// Silero VAD 会话
class SileroVadBackend {
  final sherpa.VoiceActivityDetector _vad;
  final int _sampleRate;

  SileroVadBackend._(this._vad, this._sampleRate);

  /// 当前是否检测到语音（供状态显示用）
  bool get isDetected => _vad.isDetected();

  /// 尝试创建。模型不存在 / 绑定未初始化 / 配置非法时返回 null（由调用方降级）。
  static SileroVadBackend? tryCreate({
    required String modelPath,
    required int sampleRate,
    double threshold = 0.5,
    double minSilenceDuration = 0.25,
    double minSpeechDuration = 0.25,
    double maxSpeechDuration = 8.0,
  }) {
    try {
      sherpa.initBindings();

      final config = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: modelPath,
          threshold: threshold,
          minSilenceDuration: minSilenceDuration,
          minSpeechDuration: minSpeechDuration,
          windowSize: 512,
          maxSpeechDuration: maxSpeechDuration,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      );

      // 缓冲区容量：maxSpeechDuration + 2s 余量
      final vad = sherpa.VoiceActivityDetector(
        config: config,
        bufferSizeInSeconds: maxSpeechDuration + 2.0,
      );
      return SileroVadBackend._(vad, sampleRate);
    } catch (_) {
      return null;
    }
  }

  /// 喂入一段归一化波形，收集此刻就绪的语音段
  ///
  /// [samples] 归一化 [-1, 1]；返回本次新产生的完整语音段列表。
  List<VadSegment> feed(Float32List samples) {
    final out = <VadSegment>[];
    if (samples.isEmpty) return out;

    _vad.acceptWaveform(samples);

    // 必须把内部队列取空，否则 circular buffer 会持续增长直至溢出
    var guard = 0;
    while (!_vad.isEmpty() && guard < 16) {
      guard++;
      final seg = _vad.front();
      _vad.pop();
      final pcm = float32ToPcm16(seg.samples);
      if (pcm.isEmpty) continue;
      final frames = _estimateFrames(pcm.length);
      out.add(
        VadSegment(
          pcm: pcm,
          speechFrames: frames,
          totalFrames: frames,
          sampleRate: _sampleRate,
        ),
      );
    }
    return out;
  }

  /// 停止前把残留语音吐出
  List<VadSegment> flush() {
    final out = <VadSegment>[];
    try {
      _vad.flush();
      var guard = 0;
      while (!_vad.isEmpty() && guard < 16) {
        guard++;
        final seg = _vad.front();
        _vad.pop();
        final pcm = float32ToPcm16(seg.samples);
        if (pcm.isEmpty) continue;
        final frames = _estimateFrames(pcm.length);
        out.add(
          VadSegment(
            pcm: pcm,
            speechFrames: frames,
            totalFrames: frames,
            sampleRate: _sampleRate,
          ),
        );
      }
    } catch (_) {
      // 忽略：释放阶段的失败不应阻断流程
    }
    return out;
  }

  int _estimateFrames(int pcmBytes) {
    if (_sampleRate <= 0) return 0;
    final samples = pcmBytes ~/ 2;
    return (samples * 1000 / _sampleRate / 30).round();
  }

  void dispose() {
    try {
      _vad.free();
    } catch (_) {
      // 忽略
    }
  }
}

/// Float32 [-1,1] 转 16bit 小端 PCM
Uint8List float32ToPcm16(Float32List samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.view(out.buffer);
  for (var i = 0; i < samples.length; i++) {
    var v = samples[i];
    if (v.isNaN) v = 0.0;
    if (v > 1.0) v = 1.0;
    if (v < -1.0) v = -1.0;
    var intVal = (v * 32767.0).round();
    if (intVal > 32767) intVal = 32767;
    if (intVal < -32768) intVal = -32768;
    view.setInt16(i * 2, intVal, Endian.little);
  }
  return out;
}