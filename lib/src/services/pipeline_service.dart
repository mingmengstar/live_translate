import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../models/app_state.dart';
import 'audio_capture_service.dart';
import 'asr_service.dart';
import 'translation_service.dart';
import 'overlay_service.dart';
import 'package:path_provider/path_provider.dart';

class PipelineService {
  final AudioCaptureService audioCapture = AudioCaptureService();
  final AsrService _asr = AsrService();
  final TranslationService _translation = TranslationService();
  final OverlayService overlay = OverlayService();
  
  final AppState _appState;
  StreamSubscription? _pcmSubscription;
  StreamSubscription? _audioEventSubscription;
  StreamSubscription? _asrResultSubscription;
  StreamSubscription? _asrPartialSubscription;
  StreamSubscription? _translationSubscription;
  
  String _pendingPartial = '';
  bool _isPipelineRunning = false;

  PipelineService(this._appState);

  Future<bool> initialize() async {
    try {
      _appState.setServiceState(ServiceState.starting);

      // 获取模型文件路径
      final modelPaths = await _prepareModelPaths();
      if (modelPaths == null) return false;

      // 初始化 ASR
      final asrOk = await _asr.initialize(
        encoderModelPath: modelPaths['encoder']!,
        decoderModelPath: modelPaths['decoder']!,
        joinerModelPath: modelPaths['joiner']!,
        tokensPath: modelPaths['tokens']!,
        vadModelPath: modelPaths['vad']!,
      );
      if (!asrOk) throw Exception('ASR 初始化失败');

      // 初始化翻译
      final transOk = await _translation.initialize(
        modelPath: modelPaths['translation']!,
        nCtx: 2048,
        nThreads: 4,
      );
      if (!transOk) throw Exception('翻译模型初始化失败');

      // 初始化音频捕获
      await audioCapture.initialize();

      // 初始化悬浮窗
      await overlay.initialize();

      // 检查权限
      final perms = await audioCapture.checkPermissions();
      _appState.setPermissions(
        recordAudio: perms['recordAudio'] ?? false,
        overlay: perms['overlay'] ?? false,
        notification: perms['notification'] ?? false,
        mediaProjection: perms['mediaProjection'] ?? false,
      );

      _appState.setServiceState(ServiceState.stopped);
      return true;
    } catch (e) {
      print('PipelineService initialize error: $e');
      _appState.setServiceState(ServiceState.error);
      return false;
    }
  }

  Future<Map<String, String>?> _prepareModelPaths() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${dir.path}/models');
    
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    // 从 assets 复制模型文件（首次运行）
    final modelFiles = {
      'encoder': 'encoder.onnx',
      'decoder': 'decoder.onnx',
      'joiner': 'joiner.onnx',
      'tokens': 'tokens.txt',
      'vad': 'silero_vad.onnx',
      'translation': 'hy-mt1.5-q4_k_m.gguf',
    };

    for (final entry in modelFiles.entries) {
      final destFile = File('${modelDir.path}/${entry.value}');
      if (!await destFile.exists()) {
        // 从 assets 复制模型文件
        final assetPath = 'assets/models/${entry.value}';
        try {
          final data = await rootBundle.load(assetPath);
          final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          await destFile.writeAsBytes(bytes);
          print('已从 assets 复制模型文件: ${entry.value}');
        } catch (e) {
          print('模型文件缺失: ${entry.value}，请参考 MODELS.md 下载并放入 ${modelDir.path}');
        }
      }
    }

    // 验证所有必需文件是否存在
    for (final entry in modelFiles.entries) {
      final destFile = File('${modelDir.path}/${entry.value}');
      if (!await destFile.exists()) {
        print('错误: 必需模型文件缺失: ${entry.value}');
        return null;
      }
    }

    return modelFiles.map((k, v) => MapEntry(k, '${modelDir.path}/$v'));
  }

  Future<void> startWithPermission(int mediaProjectionPermission) async {
    if (_isPipelineRunning) return;
    
    _appState.setServiceState(ServiceState.starting);
    _isPipelineRunning = true;

    // 启动音频捕获
    final captureOk = await audioCapture.startCapture(mediaProjectionPermission: mediaProjectionPermission);
    if (!captureOk) {
      _appState.setServiceState(ServiceState.error);
      _isPipelineRunning = false;
      return;
    }

    // 监听 PCM 数据流
    _pcmSubscription = audioCapture.pcmStream.listen((pcmData) {
      _asr.processAudio(pcmData);
    });

    // 监听音频事件
    _audioEventSubscription = audioCapture.eventStream.listen((event) {
      final evt = event['event'] as String?;
      if (evt == 'started') {
        _appState.setServiceState(ServiceState.running);
      } else if (evt == 'stopped') {
        stop();
      }
    });

    // 监听 ASR 最终结果
    _asrResultSubscription = _asr.resultStream.listen((text) {
      if (text.trim().isNotEmpty) {
        _translation.translate(text);
      }
    });

    // 监听 ASR 部分结果
    _asrPartialSubscription = _asr.partialStream.listen((text) {
      _pendingPartial = text;
      _appState.updateSubtitle(text, ''); // 实时显示部分识别结果
    });

    // 监听翻译结果
    _translationSubscription = _translation.resultStream.listen((translated) {
      if (translated.trim().isNotEmpty) {
        _appState.updateSubtitle(_pendingPartial, translated);
        overlay.updateSubtitle(
          original: _pendingPartial,
          translated: translated,
          fontSize: _appState.fontSize,
        );
      }
    });

    // 显示悬浮窗
    await overlay.showOverlay(fontSize: _appState.fontSize);
    _appState.setOverlayVisible(true);
  }

  Future<void> stop() async {
    if (!_isPipelineRunning) return;
    
    _appState.setServiceState(ServiceState.stopping);
    _isPipelineRunning = false;

    await _pcmSubscription?.cancel();
    await _audioEventSubscription?.cancel();
    await _asrResultSubscription?.cancel();
    await _asrPartialSubscription?.cancel();
    await _translationSubscription?.cancel();

    _pcmSubscription = null;
    _audioEventSubscription = null;
    _asrResultSubscription = null;
    _asrPartialSubscription = null;
    _translationSubscription = null;

    _asr.reset();
    await overlay.hideOverlay();
    _appState.setOverlayVisible(false);
    _appState.setServiceState(ServiceState.stopped);
  }

  void changeLanguageDirection(LanguageDirection direction) {
    _appState.setLanguageDirection(direction);
    _translation.setDirection(direction == LanguageDirection.en2ja ? 'en2ja' : 'ja2en');
  }

  Future<void> showOverlay({double? fontSize}) async {
    await overlay.showOverlay(fontSize: fontSize ?? _appState.fontSize);
    _appState.setOverlayVisible(true);
  }

  Future<void> hideOverlay() async {
    await overlay.hideOverlay();
    _appState.setOverlayVisible(false);
  }

  void dispose() {
    stop();
    _asr.dispose();
    _translation.dispose();
  }
}