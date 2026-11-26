/// Sherpa-ONNX ASR 的 isolate worker
///
/// 钢印级约束落地：所有推理（含 ONNX 前向）都在本 isolate 执行，
/// 主 isolate 只投递 PCM 字节、接收文本结果，绝不阻塞 UI 线程。
///
/// 为什么必须单独一个文件：
/// `Isolate.spawn` 的入口函数必须是**顶层函数**且不能被 tree-shaking 掉，
/// 所以用 `@pragma('vm:entry-point')` 标记。
///
/// 通信协议（只用原始类型 + TypedData，避免对象图传输开销）：
///   主 -> worker:
///     {'type':'init',  'encoder':String, 'decoder':String,
///      'joiner':String, 'tokens':String, 'numThreads':int}
///     {'type':'feed',  'pcm':Uint8List}
///     {'type':'flush'}           // 结束输入，吐出尾包
///     {'type':'reset'}           // 丢弃当前未完成的句子
///     {'type':'dispose'}
///   worker -> 主:
///     {'type':'handshake', 'port':SendPort}
///     {'type':'ready',  'ok':bool, 'note':String}
///     {'type':'result', 'text':String, 'isFinal':bool}
///     {'type':'error',  'message':String}
///     {'type':'done'}
library live_translate.core.engine.sherpa_asr_worker;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// worker 入口（必须标记 vm:entry-point）
@pragma('vm:entry-point')
void sherpaAsrWorkerEntry(SendPort parent) {
  final receiver = ReceivePort();
  _AsrSender? sender;

  // 先把自己的收件口交给 host：host 拿到后才能发 init
  parent.send({'type': 'handshake', 'port': receiver.sendPort});

  _SherpaAsrState? state;

  receiver.listen((Object? raw) {
    if (raw is! Map) return;
    final msg = raw.cast<String, Object?>();
    final type = msg['type'] as String?;
    sender ??= _AsrSender(parent);

    switch (type) {
      case 'init':
        // 重入时先彻底释放上一套模型，避免原生内存泄漏
        state?.dispose();
        try {
          state = _SherpaAsrState.create(sender!, msg);
        } catch (e) {
          sender!.send({'type': 'ready', 'ok': false, 'note': '$e'});
          state = null;
        }
        break;

      case 'feed':
        final pcm = msg['pcm'];
        if (pcm is Uint8List && state != null) {
          state!.feed(pcm, sender!);
        }
        break;

      case 'flush':
        state?.flush(sender!);
        break;

      case 'reset':
        state?.reset();
        break;

      case 'dispose':
        state?.dispose();
        state = null;
        sender!.send({'type': 'done'});
        receiver.close();
        break;

      default:
        break;
    }
  });
}

/// 极薄发送包装，统一吞掉「端口已关闭」这类无害异常
class _AsrSender {
  final SendPort _port;

  const _AsrSender(this._port);

  void send(Map<String, Object?> msg) {
    try {
      _port.send(msg);
    } catch (_) {
      // 目标已关闭时忽略
    }
  }
}

/// worker 内部状态：持有 recognizer + stream
class _SherpaAsrState {
  final sherpa.OnlineRecognizer _recognizer;
  final sherpa.OnlineStream _stream;

  /// 上一次已经上报过的中间文本，用于去重（sherpa 每帧都会返回同一句）
  String _lastText = '';

  _SherpaAsrState._(this._recognizer, this._stream);

  /// 创建并初始化。失败时抛异常，由调用方转成 `ready:false`。
  ///
  /// 注意：`initBindings()` 是 **per-isolate** 的，本 isolate 内必须先调用，
  /// 否则创建 recognizer 会抛 `Please initialize sherpa-onnx first`。
  static _SherpaAsrState create(_AsrSender out, Map<String, Object?> msg) {
    final encoder = (msg['encoder'] as String?) ?? '';
    final decoder = (msg['decoder'] as String?) ?? '';
    final joiner = (msg['joiner'] as String?) ?? '';
    final tokens = (msg['tokens'] as String?) ?? '';
    final numThreads = (msg['numThreads'] as num?)?.toInt() ?? 2;

    if (encoder.isEmpty || decoder.isEmpty || joiner.isEmpty || tokens.isEmpty) {
      throw StateError('模型路径不完整（需要 encoder / decoder / joiner / tokens）');
    }

    // FFI 绑定 per-isolate：必须在当前 isolate 内初始化
    sherpa.initBindings();

    final modelConfig = sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: encoder,
        decoder: decoder,
        joiner: joiner,
      ),
      tokens: tokens,
      // 本项目下载的是 zipformer2（transducer）结构
      modelType: 'zipformer2',
      numThreads: numThreads,
      provider: 'cpu',
      debug: false,
    );

    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: modelConfig,
        // 端点检测：一句话说完就切分，是「流式字幕」的关键
        enableEndpoint: true,
        // rule1：解码出非空白 token 后静音多久算结束
        rule1MinTrailingSilence: 2.4,
        // rule2：只解码出空白 token 后静音多久算结束
        rule2MinTrailingSilence: 1.2,
        // 单句最长 token 数，超过强制切分，防止长句撑爆内存
        rule3MinUtteranceLength: 20,
      ),
    );

    final stream = recognizer.createStream();

    out.send({
      'type': 'ready',
      'ok': true,
      'note': 'Sherpa-ONNX zipformer2 已加载 (threads=$numThreads)',
    });

    return _SherpaAsrState._(recognizer, stream);
  }

  /// 喂入一块 PCM16 单声道小端字节
  void feed(Uint8List pcm, _AsrSender out) {
    try {
      if (pcm.isEmpty) return;
      final samples = _pcm16ToFloat32(pcm);
      if (samples.isEmpty) return;

      _stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _drain(out);
    } catch (e) {
      // 单帧失败不应拖垮整条链路：上报后继续
      out.send({'type': 'error', 'message': 'ASR feed 失败: $e'});
    }
  }

  /// 把 recognizer 内部待解码的量全部跑完，并产出结果
  void _drain(_AsrSender out) {
    // while(isReady) decode 是 sherpa 官方推荐用法：
    // 每次 acceptWaveform 后可能攒了多帧特征，必须全部解码
    var guard = 0;
    while (_recognizer.isReady(_stream) && guard < 512) {
      guard++;
      _recognizer.decode(_stream);
    }

    final result = _recognizer.getResult(_stream);
    final text = result.text.trim();

    // 中间结果：只在文本真正变化时上报，避免刷屏
    if (text.isNotEmpty && text != _lastText) {
      _lastText = text;
      out.send({'type': 'result', 'text': text, 'isFinal': false});
    }

    // 端点：一句话结束，吐出最终结果并重置流
    if (_recognizer.isEndpoint(_stream)) {
      if (text.isNotEmpty) {
        out.send({'type': 'result', 'text': text, 'isFinal': true});
      }
      _recognizer.reset(_stream);
      _lastText = '';
    }
  }

  /// 停止前吐出尾包（用户刚说完就点停止时，最后一句不能丢）
  void flush(_AsrSender out) {
    try {
      _stream.inputFinished();
      var guard = 0;
      while (_recognizer.isReady(_stream) && guard < 512) {
        guard++;
        _recognizer.decode(_stream);
      }
      final text = _recognizer.getResult(_stream).text.trim();
      if (text.isNotEmpty) {
        out.send({'type': 'result', 'text': text, 'isFinal': true});
      }
      _recognizer.reset(_stream);
      _lastText = '';
    } catch (_) {
      // flush 阶段异常不向上抛，避免停止流程卡死
    }
  }

  void reset() {
    try {
      _recognizer.reset(_stream);
    } catch (_) {
      // 忽略
    }
    _lastText = '';
  }

  void dispose() {
    // 顺序很重要：先 free stream 再 free recognizer，反过来会解引用野指针
    try {
      _stream.free();
    } catch (_) {
      // 忽略
    }
    try {
      _recognizer.free();
    } catch (_) {
      // 忽略
    }
  }
}

/// 16bit 小端 PCM → 归一化 Float32（带正确符号扩展）
///
/// 与 `vad_detector.dart` 的同名实现保持一致：
/// `(hi << 8) | lo` 得到的 0~65535 必须做符号扩展，
/// 否则负样本会被当成 32768~65535 的正数，波形整体偏移。
Float32List _pcm16ToFloat32(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final lo = pcm[i * 2];
    final hi = pcm[i * 2 + 1];
    var sample = (hi << 8) | lo;
    if (sample >= 0x8000) sample -= 0x10000;
    out[i] = sample / 32768.0;
  }
  return out;
}
