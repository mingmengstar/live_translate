import 'dart:async';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

class AsrService {
  final StreamController<String> _resultController = StreamController<String>.broadcast();
  final StreamController<String> _partialController = StreamController<String>.broadcast();

  Stream<String> get resultStream => _resultController.stream;
  Stream<String> get partialStream => _partialController.stream;

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  sherpa_onnx.VoiceActivityDetector? _vad;
  bool _isInitialized = false;
  int _sampleRate = 16000;

  Future<bool> initialize({
    required String encoderModelPath,
    required String decoderModelPath,
    required String joinerModelPath,
    required String tokensPath,
    required String vadModelPath,
    int numThreads = 2,
    int sampleRate = 16000,
  }) async {
    try {
      _sampleRate = sampleRate;
      
      // 初始化 sherpa-onnx 绑定
      await sherpa_onnx.initBindingsAsync();

      // OnlineRecognizerConfig
      final featConfig = sherpa_onnx.FeatureConfig(
        sampleRate: sampleRate,
        featureDim: 80,
      );
      
      final transducerConfig = sherpa_onnx.OnlineTransducerModelConfig(
        encoder: encoderModelPath,
        decoder: decoderModelPath,
        joiner: joinerModelPath,
      );
      
      final modelConfig = sherpa_onnx.OnlineModelConfig(
        transducer: transducerConfig,
        tokens: tokensPath,
        numThreads: numThreads,
        provider: 'cpu',
      );
      
      final config = sherpa_onnx.OnlineRecognizerConfig(
        feat: featConfig,
        model: modelConfig,
      );

      _recognizer = sherpa_onnx.OnlineRecognizer(config);
      
      // VAD 配置 - 使用 VadModelConfig
      final sileroConfig = sherpa_onnx.SileroVadModelConfig(
        model: vadModelPath,
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        windowSize: 512,
      );
      
      final vadModelConfig = sherpa_onnx.VadModelConfig(
        sileroVad: sileroConfig,
        sampleRate: sampleRate,
        numThreads: numThreads,
        provider: 'cpu',
      );
      
      _vad = sherpa_onnx.VoiceActivityDetector(
        config: vadModelConfig,
        bufferSizeInSeconds: 30.0,
      );

      _isInitialized = true;
      return true;
    } catch (e) {
      print('AsrService initialize error: $e');
      return false;
    }
  }

  void processAudio(Uint8List pcmData) {
    if (!_isInitialized || _recognizer == null || _vad == null) return;

    try {
      // 将字节转换为 Float32 样本 (16-bit PCM -> float)
      final samples = Float32List(pcmData.length ~/ 2);
      for (int i = 0; i < samples.length; i++) {
        final int16 = pcmData[i * 2] | (pcmData[i * 2 + 1] << 8);
        samples[i] = int16 / 32768.0;
      }

      // VAD 处理
      _vad!.acceptWaveform(samples);

      // 检查 VAD 是否检测到语音
      if (_vad!.isDetected()) {
        // 创建新的流式识别流
        _stream ??= _recognizer!.createStream();
        _stream!.acceptWaveform(samples: samples, sampleRate: _sampleRate);
        
        // 解码
        while (_recognizer!.isReady(_stream!)) {
          _recognizer!.decode(_stream!);
        }
        
        final partial = _recognizer!.getResult(_stream!).text;
        if (partial.isNotEmpty) {
          _partialController.add(partial);
        }
      }

      // 检查 VAD 是否有完整的语音段
      if (!_vad!.isEmpty()) {
        final segment = _vad!.front();
        if (segment.samples.isNotEmpty) {
          // 将 VAD 段落送入识别器
          _stream ??= _recognizer!.createStream();
          _stream!.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
          
          while (_recognizer!.isReady(_stream!)) {
            _recognizer!.decode(_stream!);
          }
          
          final result = _recognizer!.getResult(_stream!).text;
          if (result.isNotEmpty) {
            _resultController.add(result);
          }
          _vad!.pop(); // 移除已处理的段落
        }
      }
    } catch (e) {
      print('AsrService processAudio error: $e');
    }
  }

  void reset() {
    if (_stream != null && _recognizer != null) {
      _recognizer!.reset(_stream!);
    }
    _stream = null;
  }

  void dispose() {
    _stream = null; // OnlineStream 没有 free/dispose 方法
    _recognizer?.free();
    _vad?.free();
    _resultController.close();
    _partialController.close();
    _isInitialized = false;
  }
}