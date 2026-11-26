/// VAD 检测后端抽象 + 纯 Dart 自适应能量检测器
///
/// 设计要点：
/// - 本文件不依赖 flutter / ffi / isolate，可被单元测试直接使用。
/// - 能量检测器对 16bit PCM 做**正确的 int16 符号扩展**后再算 RMS。
///   旧实现 `frame[i] | (frame[i + 1] << 8)` 会把负样本解释为 32768~65535，
///   归一化后 >1，导致 RMS 虚高 2~3 个数量级，是"误触发严重"的真实根因之一。
library live_translate.core.audio.vad.vad_detector;

import 'dart:math' as math;
import 'dart:typed_data';

import 'vad_types.dart';

/// 单帧语音判定后端
abstract interface class VadDetector {
  /// 后端类型
  VadBackend get backend;

  /// 判定一帧是否为语音
  ///
  /// [samples] 归一化到 [-1, 1] 的采样点；[pcm] 原始 16bit 字节（部分后端会用不到）。
  bool isSpeech(Float32List samples, Uint8List pcm);

  /// 释放资源
  void dispose();
}

/// 16bit 小端 PCM 转归一化 Float32（带正确符号扩展）
Float32List pcm16ToFloat32(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final lo = pcm[i * 2];
    final hi = pcm[i * 2 + 1];
    var sample = (hi << 8) | lo;
    // 符号扩展：>= 0x8000 视为负数
    if (sample >= 0x8000) sample -= 0x10000;
    out[i] = sample / 32768.0;
  }
  return out;
}

/// 计算归一化 RMS（输入已归一化采样）
double rmsOf(Float32List samples) {
  if (samples.isEmpty) return 0.0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}

/// 自适应能量 VAD
///
/// 相比原始"固定阈值 + 无滞回"实现，本版本加入三处改进：
/// 1. 正确符号扩展的 RMS（见 [pcm16ToFloat32]）。
/// 2. 自适应噪声底：仅在空闲态跟踪底噪，有效阈值 = max(绝对阈值, 底噪 × 倍数)。
///    这样安静的办公室与嘈杂的地铁都能用同一组参数，不会因为环境噪声整体抬升而持续误触发。
/// 3. 滞回（hysteresis）：进入语音用高阈值，退出语音用 高阈值 × 滞回比，
///    避免能量在阈值附近抖动导致状态反复翻转、产生大量碎片段。
class EnergyVadDetector implements VadDetector {
  /// 绝对阈值下限
  final double absoluteThreshold;

  /// 噪声底倍数
  final double noiseFloorMultiplier;

  /// 滞回比（0~1）
  final double hysteresisRatio;

  /// 噪声底跟随速率
  final double adaptRate;

  // 内部状态
  double _noiseFloor = 0.001;
  bool _inSpeech = false;

  EnergyVadDetector({
    required this.absoluteThreshold,
    required this.noiseFloorMultiplier,
    required this.hysteresisRatio,
    required this.adaptRate,
  });

  /// 当前噪声底估计（用于诊断）
  double get noiseFloor => _noiseFloor;

  /// 当前生效的进入语音阈值
  double get enterThreshold =>
      math.max(absoluteThreshold, _noiseFloor * noiseFloorMultiplier);

  /// 当前生效的退出语音阈值
  double get exitThreshold => enterThreshold * hysteresisRatio;

  @override
  VadBackend get backend => VadBackend.energy;

  @override
  bool isSpeech(Float32List samples, Uint8List pcm) {
    final rms = rmsOf(samples);

    if (_inSpeech) {
      // 语音中：用较低阈值判断是否仍为语音
      if (rms >= exitThreshold) return true;
      _inSpeech = false;
      return false;
    }

    // 空闲：跟踪噪声底（低通），并判断是否进入语音
    _noiseFloor =
        _noiseFloor * (1 - adaptRate) + math.min(rms, 0.1) * adaptRate;
    if (rms >= enterThreshold) {
      _inSpeech = true;
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _noiseFloor = 0.001;
    _inSpeech = false;
  }
}