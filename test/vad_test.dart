/// VAD 核心逻辑单元测试
///
/// 覆盖三块：
/// 1. PCM 解码符号扩展（旧实现真实 bug 的回归测试）
/// 2. 自适应能量检测器的阈值 / 滞回行为
/// 3. 分段状态机：前导静音回补、尾部裁剪、最小语音帧、强制切分重叠
library live_translate.test.vad_test;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translate/core/audio/vad/vad_detector.dart';
import 'package:live_translate/core/audio/vad/vad_segmenter.dart';
import 'package:live_translate/core/audio/vad/vad_types.dart';

/// 构造一段 16bit 小端 PCM 帧
Uint8List makePcm(int samples, double amplitude, {int phase = 0}) {
  final out = Uint8List(samples * 2);
  final view = ByteData.view(out.buffer);
  for (var i = 0; i < samples; i++) {
    final v = (math.sin((i + phase) * 0.5) * amplitude * 32767).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

/// 纯直流（便于精确断言符号）
Uint8List makeConstPcm(int samples, int value) {
  final out = Uint8List(samples * 2);
  final view = ByteData.view(out.buffer);
  for (var i = 0; i < samples; i++) {
    view.setInt16(i * 2, value, Endian.little);
  }
  return out;
}

void main() {
  group('pcm16ToFloat32 符号扩展', () {
    test('负样本必须解码为负值（旧实现 bug 回归）', () {
      // -32768 (0x8000) 小端字节为 [0x00, 0x80]
      final pcm = makeConstPcm(4, -32768);
      final samples = pcm16ToFloat32(pcm);
      expect(samples.every((s) => s < 0), isTrue);
      expect(samples.first, closeTo(-1.0, 0.001));
    });

    test('正负交替的 RMS 应收敛到正确量级', () {
      // 旧实现会把 -0.5 读成 +0.9999，导致 RMS 虚高
      final pcm = Uint8List.fromList([
        0x00, 0x40, // +16384
        0x00, 0xC0, // -16384
        0x00, 0x40,
        0x00, 0xC0,
      ]);
      final samples = pcm16ToFloat32(pcm);
      expect(samples[0], closeTo(0.5, 0.001));
      expect(samples[1], closeTo(-0.5, 0.001));
      expect(rmsOf(samples), closeTo(0.5, 0.001));
    });

    test('静音帧 RMS 接近 0', () {
      final samples = pcm16ToFloat32(makeConstPcm(160, 0));
      expect(rmsOf(samples), lessThan(0.0001));
    });
  });

  group('EnergyVadDetector', () {
    EnergyVadDetector build() => EnergyVadDetector(
      absoluteThreshold: 0.02,
      noiseFloorMultiplier: 3.0,
      hysteresisRatio: 0.6,
      adaptRate: 0.05,
    );

    test('静音不触发语音', () {
      final d = build();
      final samples = pcm16ToFloat32(makeConstPcm(480, 5));
      for (var i = 0; i < 50; i++) {
        expect(d.isSpeech(samples, makeConstPcm(480, 5)), isFalse);
      }
    });

    test('明显语音触发语音', () {
      final d = build();
      final pcm = makePcm(480, 0.5);
      expect(d.isSpeech(pcm16ToFloat32(pcm), pcm), isTrue);
    });

    test('滞回：语音中能量略低于进入阈值仍判为语音', () {
      final d = build();
      final loud = makePcm(480, 0.5);
      expect(d.isSpeech(pcm16ToFloat32(loud), loud), isTrue);

      // 进入阈值 ≈ 0.02，退出阈值 = 0.02 × 0.6 = 0.012。
      // 正弦幅度 0.02 的 RMS ≈ 0.0141：落在 [0.012, 0.02) 区间内，
      // 若没有滞回就会被判为静音，有滞回则仍算语音。
      final weak = makePcm(480, 0.02);
      expect(rmsOf(pcm16ToFloat32(weak)), lessThan(0.02));
      expect(rmsOf(pcm16ToFloat32(weak)), greaterThan(0.012));
      expect(d.isSpeech(pcm16ToFloat32(weak), weak), isTrue);
    });

    test('噪声底自适应：持续底噪抬高后不误触发', () {
      final d = build();
      final noise = makePcm(480, 0.008);
      for (var i = 0; i < 300; i++) {
        d.isSpeech(pcm16ToFloat32(noise), noise);
      }
      expect(d.noiseFloor, greaterThan(0.001));
      // 底噪抬高后，同一强度噪声不应触发
      expect(d.isSpeech(pcm16ToFloat32(noise), noise), isFalse);
    });
  });

  group('VadSegmenter', () {
    const config = VadConfig(
      silenceFrameTolerance: 3,
      minSpeechFrames: 2,
      maxBufferFrames: 8,
      sampleRate: 16000,
      frameDurationMs: 30,
    );

    test('正常语音段：静音达到容忍度后输出', () {
      final seg = VadSegmenter(
        config: config,
        leadingPadFrames: 2,
        trailingPadFrames: 1,
      );
      final frame = makeConstPcm(480, 8000);
      final out = <VadSegment>[];

      // 先喂 2 帧静音建立 ring
      seg.push(makeConstPcm(480, 0), false);
      seg.push(makeConstPcm(480, 0), false);
      // 4 帧语音
      for (var i = 0; i < 4; i++) {
        final s = seg.push(frame, true);
        if (s != null) out.add(s);
      }
      // 3 帧静音达到容忍度
      for (var i = 0; i < 3; i++) {
        final s = seg.push(makeConstPcm(480, 0), false);
        if (s != null) out.add(s);
      }

      expect(out, hasLength(1));
      // 4 语音 + 2 前导静音 + 1 尾部静音 = 7 帧
      expect(out.first.totalFrames, 7);
      expect(out.first.speechFrames, 4);
      expect(out.first.pcm.length, 7 * 480 * 2);
    });

    test('过短语音被丢弃', () {
      final seg = VadSegmenter(config: config);
      // 只 1 帧语音（低于 minSpeechFrames=2）
      seg.push(makeConstPcm(480, 8000), true);
      VadSegment? produced;
      for (var i = 0; i < 2; i++) {
        produced = seg.push(makeConstPcm(480, 0), false);
        if (produced != null) break;
      }
      expect(produced, isNull);
      // 容忍度 3 帧：2 帧静音时仍处于 trailing，第 3 帧才回到 idle
      expect(seg.state, VadState.trailing);
      expect(seg.push(makeConstPcm(480, 0), false), isNull);
      expect(seg.state, VadState.idle);
    });

    test('超长语音强制切分且保留重叠', () {
      // maxBufferFrames 属于 config（上面 const config 里已设为 8）
      final seg = VadSegmenter(config: config, overlapFrames: 2);
      final frame = makeConstPcm(480, 8000);
      final out = <VadSegment>[];
      for (var i = 0; i < 8; i++) {
        final s = seg.push(frame, true);
        if (s != null) out.add(s);
      }
      expect(out, hasLength(1));
      expect(out.first.totalFrames, 8);
    });

    test('flush 吐出未完成段', () {
      final seg = VadSegmenter(config: config);
      seg.push(makeConstPcm(480, 8000), true);
      seg.push(makeConstPcm(480, 8000), true);
      seg.push(makeConstPcm(480, 8000), true);
      final s = seg.flush();
      expect(s, isNotNull);
      expect(s!.speechFrames, 3);
    });

    test('reset 后状态回到 idle', () {
      final seg = VadSegmenter(config: config);
      seg.push(makeConstPcm(480, 8000), true);
      seg.reset();
      expect(seg.state, VadState.idle);
      expect(seg.flush(), isNull);
    });
  });

  group('VadSegment.duration', () {
    test('按采样数换算时长', () {
      // 16000 Hz, 16000 个样本 = 1s = 32000 字节
      final seg = VadSegment(
        pcm: Uint8List(32000),
        speechFrames: 100,
        totalFrames: 100,
        sampleRate: 16000,
      );
      expect(seg.duration.inMilliseconds, 1000);
    });

    test('空段返回 0', () {
      final seg = VadSegment(
        pcm: Uint8List(0),
        speechFrames: 0,
        totalFrames: 0,
        sampleRate: 16000,
      );
      expect(seg.duration, Duration.zero);
      expect(seg.speechDuration, Duration.zero);
    });
  });
}