/// VAD 服务（主 isolate 侧的 host）
///
/// 对上层暴露简洁 API，内部管理 Isolate + 双向端口：
///   - init(config)  启动 isolate，加载后端（Silero 优先，失败降级）
///   - feed(pcm)     投递原始 PCM（非阻塞，立即返回）
///   - flush()       停止前吐出残留段
///   - dispose()     干净关闭（钢印级：切引擎/关服务必须释放）
///
/// 崩溃防护：
///   - isolate 创建失败、worker 报错、端口关闭都只记录事件并通过 onError 上报，
///     不向上抛异常，避免拖垮 UI 线程。
///   - 待处理数据设为"有界队列"，音频异常爆量时丢弃最旧数据而不是无限堆积。
library live_translate.core.audio.vad.vad_service;

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'dart:typed_data';

import 'vad_isolate_worker.dart';
import 'vad_types.dart';

/// VAD 服务对外事件回调集合
class VadCallbacks {
  /// 后端就绪（Silero 或能量）
  final void Function(VadBackend backend, String note)? onReady;

  /// 产出完整语音段
  final void Function(VadSegment segment)? onSegment;

  /// 状态变化
  final void Function(VadState state)? onStateChanged;

  /// 电平（约 600ms 一次，供 UI 显示）
  final void Function(double rms)? onLevel;

  /// 错误（不致命，仅提示）
  final void Function(String message)? onError;

  const VadCallbacks({
    this.onReady,
    this.onSegment,
    this.onStateChanged,
    this.onLevel,
    this.onError,
  });
}

/// VAD 服务
class VadService {
  static const String _tag = 'VadService';

  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _hostPort;
  StreamSubscription<dynamic>? _sub;

  VadCallbacks _callbacks = const VadCallbacks();
  VadBackend _backend = VadBackend.energy;
  VadState _state = VadState.idle;
  String? _lastNote;
  bool _disposed = false;
  bool _starting = false;

  /// 当前后端
  VadBackend get backend => _backend;

  /// 当前状态
  VadState get state => _state;

  /// 后端初始化说明（给 UI 显示"当前使用 Silero / 能量 VAD"）
  String? get backendNote => _lastNote;

  /// 是否已就绪
  bool get isReady => _workerPort != null && _isolate != null;

  /// 启动 isolate
  ///
  /// 返回 true 表示 worker 已就绪（后端可能已降级，可读 [backend] 判断）。
  Future<bool> start({
    VadConfig config = const VadConfig(),
    required VadCallbacks callbacks,
  }) async {
    if (_starting || isReady) return isReady;
    _starting = true;
    _disposed = false;
    _callbacks = callbacks;

    final hostPort = ReceivePort();
    final readyCompleter = Completer<bool>();

    // 超时兜底：某些设备 isolate 启动慢或模型缺失，不让上层无限等待
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!readyCompleter.isCompleted) {
        dev.log('[$_tag] worker 启动超时', name: _tag);
        _callbacks.onError?.call('VAD 启动超时，已跳过');
        readyCompleter.complete(false);
      }
    });

    try {
      final isolate = await Isolate.spawn(
        vadWorkerEntry,
        hostPort.sendPort,
        debugName: 'vad-worker',
        errorsAreFatal: false,
      );
      _isolate = isolate;
      _hostPort = hostPort;

      _sub = hostPort.listen((Object? raw) {
        if (raw is! Map) return;
        final msg = raw.cast<String, Object?>();
        final type = msg['type'] as String?;

        switch (type) {
          case 'handshake':
            final port = msg['port'];
            if (port is SendPort) {
              _workerPort = port;
              // 拿到 worker 端口后才能发 init
              port.send({
                'type': 'init',
                'config': _configToMap(config),
              });
            }
            break;

          case 'ready':
            _backend = vadBackendFromWire(
              msg['backend'] as String? ?? 'energy',
            );
            _lastNote = msg['note'] as String?;
            dev.log(
              '[$_tag] 后端就绪: $_backend ($_lastNote)',
              name: _tag,
            );
            _callbacks.onReady?.call(_backend, _lastNote ?? '');
            if (!readyCompleter.isCompleted) readyCompleter.complete(true);
            break;

          case 'segment':
            final pcm = msg['pcm'];
            if (pcm is Uint8List) {
              _callbacks.onSegment?.call(
                VadSegment(
                  pcm: pcm,
                  speechFrames: (msg['speechFrames'] as num?)?.toInt() ?? 0,
                  totalFrames: (msg['totalFrames'] as num?)?.toInt() ?? 0,
                  sampleRate: (msg['sampleRate'] as num?)?.toInt() ?? 16000,
                ),
              );
            }
            break;

          case 'state':
            final next = vadStateFromWire(msg['state'] as String? ?? 'idle');
            if (next != _state) {
              _state = next;
              _callbacks.onStateChanged?.call(next);
            }
            break;

          case 'level':
            final rms = (msg['rms'] as num?)?.toDouble() ?? 0.0;
            _callbacks.onLevel?.call(rms);
            break;

          case 'error':
            final message = msg['message'] as String? ?? '未知 VAD 错误';
            dev.log('[$_tag] worker 错误: $message', name: _tag);
            _callbacks.onError?.call(message);
            break;

          case 'flushed':
          case 'done':
            break;

          default:
            break;
        }
      }, onError: (Object e) {
        dev.log('[$_tag] host 端口错误: $e', name: _tag);
        _callbacks.onError?.call('VAD 通信异常: $e');
      });

      final ok = await readyCompleter.future;
      _starting = false;
      if (!ok) {
        await _teardown();
        return false;
      }
      return true;
    } catch (e, s) {
      dev.log('[$_tag] 启动失败: $e\n$s', name: _tag);
      _callbacks.onError?.call('VAD 启动失败: $e');
      _starting = false;
      await _teardown();
      return false;
    } finally {
      timeout.cancel();
    }
  }

  /// 投递原始 PCM（16bit 单声道小端）
  ///
  /// 非阻塞：仅做一次 send；worker 侧按帧重新切分。
  void feed(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final port = _workerPort;
    if (port == null || _disposed) return;
    try {
      port.send({'type': 'feed', 'pcm': pcm});
    } catch (e) {
      dev.log('[$_tag] feed 失败: $e', name: _tag);
    }
  }

  /// 停止前吐出残留语音段
  void flush() {
    final port = _workerPort;
    if (port == null) return;
    try {
      port.send({'type': 'flush'});
    } catch (_) {
      // 忽略
    }
  }

  /// 重置内部状态（重新开始录音时用）
  void reset() {
    final port = _workerPort;
    if (port == null) return;
    try {
      port.send({'type': 'reset'});
    } catch (_) {
      // 忽略
    }
    _state = VadState.idle;
  }

  /// 彻底释放（钢印级：必须能干净关闭）
  Future<void> dispose() async {
    _disposed = true;
    await _teardown();
  }

  Future<void> _teardown() async {
    final port = _workerPort;
    if (port != null) {
      try {
        port.send({'type': 'dispose'});
      } catch (_) {
        // 忽略
      }
      // 仅在确实启动过 worker 时才等待，给 worker 时间 free() 原生资源；
      // 未启动时不留任何挂起定时器（否则 widget 测试会报 timersPending）。
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    await _sub?.cancel();
    _sub = null;
    _hostPort?.close();
    _hostPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
    _state = VadState.idle;
  }

  /// VadConfig -> 可跨 isolate 传递的 Map（只用原始类型）
  static Map<String, Object?> _configToMap(VadConfig c) => {
        'sampleRate': c.sampleRate,
        'frameDurationMs': c.frameDurationMs,
        'energyThreshold': c.energyThreshold,
        'noiseFloorMultiplier': c.noiseFloorMultiplier,
        'hysteresisRatio': c.hysteresisRatio,
        'noiseFloorAdaptRate': c.noiseFloorAdaptRate,
        'silenceFrameTolerance': c.silenceFrameTolerance,
        'minSpeechFrames': c.minSpeechFrames,
        'maxBufferFrames': c.maxBufferFrames,
        'preferSilero': c.preferSilero,
        'sileroModelPath': c.sileroModelPath,
        'sileroThreshold': c.sileroThreshold,
        'sileroMinSilenceDuration': c.sileroMinSilenceDuration,
        'sileroMinSpeechDuration': c.sileroMinSpeechDuration,
        'sileroMaxSpeechDuration': c.sileroMaxSpeechDuration,
      };
}