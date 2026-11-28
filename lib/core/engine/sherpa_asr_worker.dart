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
  ///
  /// ## v0.8.0：stream 可重建（修「停止一次再开始就再也识别不出」）
  ///
  /// 旧实现只有一个 `final` stream，而 `flush()` 会调用
  /// `_stream.inputFinished()`。在 sherpa-onnx 里这个标志是**不可逆**的：
  /// `reset()` 不会清除它，之后所有 `acceptWaveform()` 都会被直接丢弃。
  ///
  /// 结果是：用户点一次「停止」再点「开始」，识别永久失效，只能杀进程。
  /// 现在 `_stream` 改为可变，`flush()` 结束后立刻 free 旧流并重建一条新的。
  class _SherpaAsrState {
    final sherpa.OnlineRecognizer _recognizer;
    sherpa.OnlineStream _stream;

    /// 上一次已经上报过的中间文本，用于去重（sherpa 每帧都会返回同一句）
    String _lastText = '';

    /// 是否已经终结过一个完整句子（供宿主判断是否需要新建字幕条目）
    bool _utteranceClosed = false;

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
        // 本项目下载的是 zipformer（transducer）结构
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
          //
          // 2.4s 是 sherpa 的默认值，对「边说边译」来说太长了：
          // 用户说完要等 2.4 秒字幕才定稿。降到 0.8s 更贴合字幕体感，
          // 同时仍能容忍句中正常的换气停顿（普通停顿约 0.3~0.6s）。
          rule1MinTrailingSilence: 0.8,
          // rule2：只解码出空白 token 后静音多久算结束
          rule2MinTrailingSilence: 0.6,
          // rule3：单句最长时长（**单位是秒**，不是 token 数！）
          //
          // 上游默认 20s。字幕场景下 20s 太长，一句会堆积过多文字，
          // 中文长句也容易在解码后期发散。压到 10s 强制收尾。
          rule3MinUtteranceLength: 10,
        ),
      );

      final stream = recognizer.createStream();

      out.send({
        'type': 'ready',
        'ok': true,
        'note': 'Sherpa-ONNX zipformer 已加载 (threads=$numThreads)',
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
  ///
  /// ## v0.8.0 修复：同一句不再上报两次
  ///
  /// 旧实现的问题：`_lastText` 只用于给**中间结果**去重，端点分支完全
  /// 不看它 —— 于是「最后一句中间结果」和「同一句的最终结果」会以
  /// `isFinal: false` / `isFinal: true` 各发一次。
  ///
  /// 上游 `TranslationService` 收到 `isFinal: true` 就翻译并入库，
  /// 而中间结果也会实时上屏，用户看到的就是「同一句话反复出现」，
  /// 并且每次都会重新触发一次翻译。
  ///
  /// 现在的规则：
  /// - 中间结果：文本变化才发（保留原有去重）；
  /// - 端点：只有当「最终文本与上次发出的文本不同」，或者上次发的是
  ///   中间结果（即需要一次 `isFinal` 来收尾）时才发。
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
    final isEndpoint = _recognizer.isEndpoint(_stream);

    if (text.isEmpty && !isEndpoint) return;

    // 端点：本句说话结束
    if (isEndpoint) {
      // 只有文本非空且确实需要收尾时才上报 isFinal
      if (text.isNotEmpty && !_utteranceClosed) {
        _utteranceClosed = true;
        _lastText = text;
        out.send({'type': 'result', 'text': text, 'isFinal': true});
      }
      _resetStream();
      return;
    }

    // 中间结果：只在文本真正变化时上报，避免刷屏与重复翻译
    if (text.isNotEmpty && text != _lastText) {
      _lastText = text;
      _utteranceClosed = false;
      out.send({'type': 'result', 'text': text, 'isFinal': false});
    }
  }

  /// 重建 stream（端点后调用）
  ///
  /// 为什么不用 `_recognizer.reset(_stream)`：
  /// 端点后 `reset` 也能工作，但它**不会清除** `inputFinished` 标志。
  /// 一旦 `flush()` 曾经调用过 `inputFinished()`，这个 stream 就永久废了。
  /// 统一改走「free 旧流 + 建新流」，行为简单且不会留下坏状态。
  void _resetStream() {
    try {
      _stream.free();
    } catch (_) {
      // 释放失败不应阻断后续识别
    }
    _stream = _recognizer.createStream();
    _lastText = '';
    _utteranceClosed = false;
  }

  /// 停止前吐出尾包（用户刚说完就点停止时，最后一句不能丢）
  void flush(_AsrSender out) {
    try {
      // inputFinished 会让解码器把缓冲中的特征全部吐完。
      // ⚠️ 这个标志不可逆，所以结束后必须换一条新 stream（见 _resetStream）。
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
    } catch (_) {
      // flush 阶段异常不向上抛，避免停止流程卡死
    } finally {
      // 无论如何都要换新流：否则下一次 start 后 acceptWaveform 全被丢弃
      _resetStream();
    }
  }

  void reset() {
    _resetStream();
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
