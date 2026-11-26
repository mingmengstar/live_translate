/// VAD 分段状态机（纯 Dart，无 flutter/ffi 依赖）
///
/// 职责：把逐帧的 isSpeech 判定，变成"完整的语音段"。
/// 相比旧实现的改进：
/// - 进入语音时**回补前导静音帧**（默认 3 帧 ≈ 90ms），避免 ASR 丢掉词首辅音。
/// - 段尾保留静音帧有限（tailPad），并可从段内裁剪，避免每段都拖长尾巴。
/// - 强制切分（maxBufferFrames）时保留少量重叠（overlap），避免长句在切点断词。
/// - 提供 reset()/flush() 语义，停止录音时能吐出最后一段。
library live_translate.core.audio.vad.vad_segmenter;

import 'dart:typed_data';

import 'vad_types.dart';

/// 分段状态机
class VadSegmenter {
  final VadConfig config;

  /// 进入语音时向前回补的静音帧数
  final int leadingPadFrames;

  /// 段尾保留的静音帧数
  final int trailingPadFrames;

  /// 强制切分后保留的重叠帧数
  final int overlapFrames;

  final List<Uint8List> _ring = [];
  final List<Uint8List> _speech = [];

  int _silenceFrames = 0;
  int _speechFrameCount = 0;
  VadState _state = VadState.idle;

  VadSegmenter({
    required this.config,
    this.leadingPadFrames = 3,
    this.trailingPadFrames = 2,
    this.overlapFrames = 2,
  });

  VadState get state => _state;

  /// 索引 0 = 最旧
  List<Uint8List> get _ringList => _ring;

  void _pushRing(Uint8List frame) {
    _ring.add(frame);
    if (_ring.length > leadingPadFrames) {
      _ring.removeAt(0);
    }
  }

  /// 喂入一帧，返回需要吐出的语音段（0 或 1 个）
  VadSegment? push(Uint8List frame, bool isSpeech) {
    switch (_state) {
      case VadState.idle:
        if (isSpeech) {
          _state = VadState.speaking;
          _speechFrameCount = 1;
          _silenceFrames = 0;
          _speech
            ..clear()
            ..addAll(_ringList) // 回补前导静音
            ..add(frame);
          _ring.clear();
          // 立即检查是否已超长（极长连续语音但缓冲区很小的极端参数）
          return _checkOverflow();
        }
        _pushRing(frame);
        return null;

      case VadState.speaking:
        _speech.add(frame);
        if (isSpeech) {
          // 只有语音帧才计入语音帧数；静音帧只推进静音计数
          _speechFrameCount++;
          _silenceFrames = 0;
        } else {
          _silenceFrames = 1;
          _state = VadState.trailing;
        }
        return _checkOverflow();

      case VadState.trailing:
        _speech.add(frame);
        if (isSpeech) {
          _state = VadState.speaking;
          _silenceFrames = 0;
          _speechFrameCount++;
          return _checkOverflow();
        }
        _silenceFrames++;
        if (_silenceFrames >= config.silenceFrameTolerance) {
          final seg = _emit(_speech, _speechFrameCount);
          _resetToIdle();
          return seg;
        }
        return null;
    }
  }

  /// 缓冲区超长时强制切分
  VadSegment? _checkOverflow() {
    if (_speech.length < config.maxBufferFrames) return null;
    // 保留最后 overlapFrames 帧，作为下一段的开头，避免断词
    final overlap = overlapFrames.clamp(0, _speech.length);
    final tail = _speech.sublist(_speech.length - overlap);
    final seg = _emit(_speech, _speechFrameCount);
    _speech
      ..clear()
      ..addAll(tail);
    _speechFrameCount = overlap;
    _state = VadState.speaking;
    _silenceFrames = 0;
    return seg;
  }

  /// 停止/释放前，把缓冲区里的东西吐出来（如果够长）
  VadSegment? flush() {
    if (_speech.isEmpty) return null;
    final seg = _emit(_speech, _speechFrameCount);
    _resetToIdle();
    return seg;
  }

  /// 重置状态（不产出段）
  void reset() {
    _speech.clear();
    _ring.clear();
    _silenceFrames = 0;
    _speechFrameCount = 0;
    _state = VadState.idle;
  }

  void _resetToIdle() {
    _speech.clear();
    _ring.clear();
    _silenceFrames = 0;
    _speechFrameCount = 0;
    _state = VadState.idle;
  }

  /// 组装段；不足最小语音帧数则丢弃（返回 null）
  VadSegment? _emit(List<Uint8List> frames, int speechFrames) {
    if (frames.isEmpty) return null;
    if (speechFrames < config.minSpeechFrames) return null;

    // 裁剪多余尾部静音：仅保留 trailingPadFrames 帧
    var dropTail = 0;
    if (_silenceFrames > trailingPadFrames) {
      dropTail = _silenceFrames - trailingPadFrames;
    }
    final effective = dropTail > 0
        ? frames.sublist(0, frames.length - dropTail.clamp(0, frames.length))
        : frames;
    if (effective.isEmpty) return null;

    var total = 0;
    for (final f in effective) {
      total += f.length;
    }
    final pcm = Uint8List(total);
    var offset = 0;
    for (final f in effective) {
      pcm.setRange(offset, offset + f.length, f);
      offset += f.length;
    }

    return VadSegment(
      pcm: pcm,
      speechFrames: speechFrames,
      totalFrames: effective.length,
      sampleRate: config.sampleRate,
    );
  }
}