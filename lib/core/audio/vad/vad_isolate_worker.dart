/// VAD isolate worker
///
/// 钢印级约束落地：所有 VAD 推理（含 Silero ONNX 前向）都在本 isolate 执行，
/// 主 isolate 只负责投递字节、接收结果，绝不阻塞 UI 线程。
///
/// 通信协议（只用原始类型 + TypedData，避免对象图传输开销）：
///   主 -> worker:
///     `{'type':'init', 'config':Map<String,Object?>}`
///     {'type':'feed',    'pcm':Uint8List}
///     {'type':'flush'}
///     {'type':'reset'}
///     {'type':'dispose'}
///   worker -> 主:
///     {'type':'ready',   'backend':'silero'|'energy', 'note':String}
///     `{'type':'segment', 'pcm':Uint8List, 'speechFrames':int, 'totalFrames':int}`
///     {'type':'state',   'state':'idle'|'speaking'|'trailing'}
///     {'type':'level',   'rms':double}
///     {'type':'error',   'message':String}
///     {'type':'flushed'}
///     {'type':'done'}
///
/// 注：上面的花括号只是字段示意，实际消息体就是普通 Map。
/// 握手：worker 一启动就把自己的 SendPort 发给 host（host 必须先拿到它才能发 init）。
library live_translate.core.audio.vad.vad_isolate_worker;

import 'dart:isolate';
import 'dart:typed_data';

import 'silero_vad_backend.dart';
import 'vad_detector.dart';
import 'vad_segmenter.dart';
import 'vad_types.dart';

/// worker 入口（必须标记 vm:entry-point）
@pragma('vm:entry-point')
void vadWorkerEntry(SendPort parent) {
  final receiver = ReceivePort();
  _VadWorkerState? state;

  // 先把本 isolate 的收件口交给 host
  parent.send({'type': 'handshake', 'port': receiver.sendPort});

  receiver.listen((Object? raw) {
    if (raw is! Map) return;
    final msg = raw.cast<String, Object?>();
    final type = msg['type'] as String?;
    final out = _Sender(parent);

    switch (type) {
      case 'init':
        state?.dispose();
        state = _VadWorkerState(out, msg['config'] as Map?);
        break;

      case 'feed':
        final pcm = msg['pcm'];
        if (pcm is Uint8List && state != null) {
          state!.feed(pcm, out);
        }
        break;

      case 'flush':
        state?.flush(out);
        out.send({'type': 'flushed'});
        break;

      case 'reset':
        state?.reset();
        break;

      case 'dispose':
        state?.dispose();
        state = null;
        out.send({'type': 'done'});
        receiver.close();
        break;

      default:
        break;
    }
  });
}

/// 极薄发送包装，统一吞掉"端口已关闭"这类无害异常
class _Sender {
  final SendPort _port;

  const _Sender(this._port);

  void send(Map<String, Object?> msg) {
    try {
      _port.send(msg);
    } catch (_) {
      // 目标已关闭时忽略
    }
  }
}

/// worker 内部状态机：持有后端 + 分段器
class _VadWorkerState {
  final _Sender _out;
  final VadConfig _config;

  VadDetector? _energy;
  SileroVadBackend? _silero;
  VadSegmenter? _segmenter;
  VadBackend _backend = VadBackend.energy;

  // 原始数据待重新分帧缓冲
  final List<int> _raw = [];
  VadState _lastState = VadState.idle;
  int _levelCounter = 0;

  _VadWorkerState(this._out, Map? configMap) : _config = _parse(configMap) {
    _boot();
  }

  static VadConfig _parse(Map? m) {
    if (m == null) return const VadConfig();

    double d(String k, double def) {
      final v = m[k];
      return v is num ? v.toDouble() : def;
    }

    int i(String k, int def) {
      final v = m[k];
      return v is num ? v.toInt() : def;
    }

    bool b(String k, bool def) {
      final v = m[k];
      return v is bool ? v : def;
    }

    final modelPath = m['sileroModelPath'];
    return VadConfig(
      sampleRate: i('sampleRate', 16000),
      frameDurationMs: i('frameDurationMs', 30),
      energyThreshold: d('energyThreshold', 0.02),
      noiseFloorMultiplier: d('noiseFloorMultiplier', 3.0),
      hysteresisRatio: d('hysteresisRatio', 0.6),
      noiseFloorAdaptRate: d('noiseFloorAdaptRate', 0.05),
      silenceFrameTolerance: i('silenceFrameTolerance', 10),
      minSpeechFrames: i('minSpeechFrames', 3),
      maxBufferFrames: i('maxBufferFrames', 300),
      preferSilero: b('preferSilero', true),
      sileroModelPath:
          modelPath is String && modelPath.isNotEmpty ? modelPath : null,
      sileroThreshold: d('sileroThreshold', 0.5),
      sileroMinSilenceDuration: d('sileroMinSilenceDuration', 0.25),
      sileroMinSpeechDuration: d('sileroMinSpeechDuration', 0.25),
      sileroMaxSpeechDuration: d('sileroMaxSpeechDuration', 8.0),
    );
  }

  void _boot() {
    var note = '';

    // 1) 优先 Silero（需模型路径 + 原生绑定可用）
    if (_config.preferSilero && _config.sileroModelPath != null) {
      _silero = SileroVadBackend.tryCreate(
        modelPath: _config.sileroModelPath!,
        sampleRate: _config.sampleRate,
        threshold: _config.sileroThreshold,
        minSilenceDuration: _config.sileroMinSilenceDuration,
        minSpeechDuration: _config.sileroMinSpeechDuration,
        maxSpeechDuration: _config.sileroMaxSpeechDuration,
      );
      if (_silero != null) {
        _backend = VadBackend.silero;
        note = 'Silero VAD 已加载';
      } else {
        note = 'Silero 模型加载失败，已降级为能量 VAD';
      }
    } else if (_config.preferSilero) {
      note = '未提供 Silero 模型，使用能量 VAD';
    }

    // 2) 兜底：能量 VAD + 分段器
    if (_backend == VadBackend.energy) {
      _energy = EnergyVadDetector(
        absoluteThreshold: _config.energyThreshold,
        noiseFloorMultiplier: _config.noiseFloorMultiplier,
        hysteresisRatio: _config.hysteresisRatio,
        adaptRate: _config.noiseFloorAdaptRate,
      );
      _segmenter = VadSegmenter(config: _config);
    }

    _out.send({
      'type': 'ready',
      'backend': vadBackendToWire(_backend),
      'note': note,
    });
  }

  void feed(Uint8List pcm, _Sender out) {
    try {
      _raw.addAll(pcm);
      final bytesPerFrame = _config.bytesPerFrame;
      if (bytesPerFrame <= 0) return;

      while (_raw.length >= bytesPerFrame) {
        final frame = Uint8List.fromList(_raw.sublist(0, bytesPerFrame));
        _raw.removeRange(0, bytesPerFrame);
        _processFrame(frame, out);
      }
    } catch (e) {
      _out.send({'type': 'error', 'message': 'VAD feed 失败: $e'});
    }
  }

  void _processFrame(Uint8List frame, _Sender out) {
    final samples = pcm16ToFloat32(frame);

    if (_backend == VadBackend.silero && _silero != null) {
      for (final seg in _silero!.feed(samples)) {
        _emitSegment(seg, out);
      }
      _maybeEmitLevel(samples, out);
      return;
    }

    final isSpeech = _energy!.isSpeech(samples, frame);
    final seg = _segmenter!.push(frame, isSpeech);

    final state = _segmenter!.state;
    if (state != _lastState) {
      _lastState = state;
      out.send({'type': 'state', 'state': vadStateToWire(state)});
    }
    if (seg != null) {
      _emitSegment(seg, out);
    }
    _maybeEmitLevel(samples, out);
  }

  /// 降低消息频率：约 20 帧（600ms）上报一次电平，供 UI 画波形用
  void _maybeEmitLevel(Float32List samples, _Sender out) {
    _levelCounter++;
    if (_levelCounter % 20 != 0) return;
    out.send({'type': 'level', 'rms': rmsOf(samples)});
  }

  void _emitSegment(VadSegment seg, _Sender out) {
    out.send({
      'type': 'segment',
      'pcm': seg.pcm,
      'speechFrames': seg.speechFrames,
      'totalFrames': seg.totalFrames,
      'sampleRate': seg.sampleRate,
    });
  }

  void flush(_Sender out) {
    try {
      if (_backend == VadBackend.silero && _silero != null) {
        for (final seg in _silero!.flush()) {
          _emitSegment(seg, out);
        }
      } else if (_segmenter != null) {
        final seg = _segmenter!.flush();
        if (seg != null) _emitSegment(seg, out);
      }
      _raw.clear();
    } catch (_) {
      // flush 阶段异常不向上抛，避免停止流程卡死
    }
  }

  void reset() {
    _raw.clear();
    _segmenter?.reset();
    _lastState = VadState.idle;
  }

  void dispose() {
    _raw.clear();
    _energy?.dispose();
    _energy = null;
    _silero?.dispose();
    _silero = null;
    _segmenter = null;
  }
}