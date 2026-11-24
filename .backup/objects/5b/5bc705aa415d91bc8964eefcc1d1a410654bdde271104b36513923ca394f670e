/// 音频捕获服务
/// 集成 system_audio_recorder 进行系统内录，实现 VAD 语音活动检测
/// 将 16kHz 单声道 PCM 音频切片推送给 ASR 引擎
import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:system_audio_recorder/system_audio_recorder.dart';

/// VAD 处理器配置
class VadConfig {
  /// 采样率 (Hz)
  final int sampleRate;
  
  /// 帧长度 (ms)，必须是 10, 20, 30 之一（WebRTC VAD 要求）
  final int frameDurationMs;
  
  /// 能量阈值（简单 VAD 模式下使用）
  final double energyThreshold;
  
  /// 静音帧容忍数（连续多少静音帧判定为语音结束）
  final int silenceFrameTolerance;
  
  /// 最小语音帧数（最少多少帧才算有效语音段）
  final int minSpeechFrames;
  
  /// 最大缓冲帧数（防止内存溢出）
  final int maxBufferFrames;

  const VadConfig({
    this.sampleRate = 16000,
    this.frameDurationMs = 30,
    this.energyThreshold = 0.02,
    this.silenceFrameTolerance = 10,
    this.minSpeechFrames = 3,
    this.maxBufferFrames = 300, // 约 9 秒 @ 30ms/帧
  });

  /// 每帧的采样点数
  int get samplesPerFrame => (sampleRate * frameDurationMs / 1000).round();
  
  /// 每帧的字节数 (16bit = 2 bytes)
  int get bytesPerFrame => samplesPerFrame * 2;
}

/// VAD 状态
enum VadState {
  idle,       // 空闲，等待语音开始
  speaking,   // 语音中
  trailing,   // 尾部静音，等待确认语音结束
}

/// 音频捕获服务
/// 负责系统内录、VAD 处理、音频分段推送给 ASR
class AudioCaptureService {
  static final AudioCaptureService _instance = AudioCaptureService._internal();
  factory AudioCaptureService() => _instance;
  AudioCaptureService._internal();

  // 配置
  VadConfig _config = const VadConfig();
  
  // 状态
  bool _isRecording = false;
  VadState _vadState = VadState.idle;
  
  // VAD 缓冲区
  final List<Uint8List> _speechBuffer = [];
  int _silenceFrameCount = 0;
  int _speechFrameCount = 0;
  
  // 回调
  Function(Uint8List)? _onAudioSegment;
  
  // 音频流订阅
  StreamSubscription<dynamic>? _audioSubscription;

  // 原始数据缓冲区（用于重新分帧）
  final List<int> _rawBuffer = [];

  /// 是否正在录音
  bool get isRecording => _isRecording;
  
  /// 当前 VAD 状态
  VadState get vadState => _vadState;

  /// 初始化音频捕获服务
  Future<void> initialize({
    VadConfig? config,
    required Function(Uint8List) onAudioSegment,
  }) async {
    _config = config ?? const VadConfig();
    _onAudioSegment = onAudioSegment;
    
    // 请求录音权限
    final granted = await SystemAudioRecorder.requestRecord(
      titleNotification: '实时翻译',
      messageNotification: '正在录制系统音频用于翻译',
    );
    if (!granted) {
      throw StateError('录音权限被拒绝');
    }
    
    log('[AudioCapture] 初始化完成: ${_config.sampleRate}Hz, ${_config.frameDurationMs}ms/帧', name: 'AudioCapture');
  }

  /// 开始捕获系统音频
  Future<void> start() async {
    if (_isRecording) return;
    
    try {
      // 启动系统内录 (16kHz, 单声道, 16bit PCM)
      // bufferSize: 640 samples @ 16kHz = 40ms buffer
      final started = await SystemAudioRecorder.startRecord(
        sampleRate: _config.sampleRate,
        bufferSize: _config.samplesPerFrame, // 与 VAD 帧大小一致
        toStream: true,
        toFile: false,
      );
      
      if (!started) {
        throw StateError('启动系统录音失败');
      }
      
      _isRecording = true;
      _vadState = VadState.idle;
      _speechBuffer.clear();
      _rawBuffer.clear();
      _silenceFrameCount = 0;
      _speechFrameCount = 0;
      
      // 监听音频流 (EventChannel)
      _audioSubscription = SystemAudioRecorder.audioStream
          .receiveBroadcastStream()
          .map((data) => data as List<int>)
          .listen(
        _onAudioDataReceived,
        onError: (error) {
          log('[AudioCapture] 音频流错误: $error', name: 'AudioCapture');
        },
        onDone: () {
          log('[AudioCapture] 音频流结束', name: 'AudioCapture');
        },
      );
      
      log('[AudioCapture] 开始捕获系统音频', name: 'AudioCapture');
    } catch (e, stack) {
      _isRecording = false;
      log('[AudioCapture] 启动失败: $e\n$stack', name: 'AudioCapture');
      rethrow;
    }
  }

  /// 接收音频数据（从 EventChannel）
  void _onAudioDataReceived(List<int> data) {
    if (!_isRecording) return;
    
    // 转换为 Uint8List 并处理
    final frame = Uint8List.fromList(data);
    _processRawAudio(frame);
  }

  /// 停止捕获
  Future<void> stop() async {
    if (!_isRecording) return;
    
    try {
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      
      await SystemAudioRecorder.stopRecord();
      
      // 处理缓冲区中剩余的语音段
      if (_speechBuffer.isNotEmpty && _speechFrameCount >= _config.minSpeechFrames) {
        final segment = _concatFrames(_speechBuffer);
        _onAudioSegment?.call(segment);
      }
      
      _speechBuffer.clear();
      _rawBuffer.clear();
      _isRecording = false;
      _vadState = VadState.idle;
      
      log('[AudioCapture] 停止捕获', name: 'AudioCapture');
    } catch (e, stack) {
      log('[AudioCapture] 停止失败: $e\n$stack', name: 'AudioCapture');
    }
  }

  /// 处理原始音频数据（重新分帧为 VAD 所需大小）
  void _processRawAudio(Uint8List data) {
    _rawBuffer.addAll(data);
    
    while (_rawBuffer.length >= _config.bytesPerFrame) {
      final frame = Uint8List.fromList(_rawBuffer.sublist(0, _config.bytesPerFrame));
      _rawBuffer.removeRange(0, _config.bytesPerFrame);
      _processAudioFrame(frame);
    }
  }

  /// 处理音频帧（VAD 核心逻辑）
  void _processAudioFrame(Uint8List frame) {
    // 简单能量 VAD
    final energy = _calculateEnergy(frame);
    final isSpeech = energy > _config.energyThreshold;
    
    switch (_vadState) {
      case VadState.idle:
        if (isSpeech) {
          // 语音开始
          _vadState = VadState.speaking;
          _speechFrameCount = 1;
          _silenceFrameCount = 0;
          _speechBuffer.add(frame);
        }
        break;
        
      case VadState.speaking:
        _speechBuffer.add(frame);
        
        if (isSpeech) {
          _speechFrameCount++;
          _silenceFrameCount = 0;
        } else {
          _silenceFrameCount++;
          _vadState = VadState.trailing;
        }
        
        // 缓冲区溢出保护
        if (_speechBuffer.length >= _config.maxBufferFrames) {
          _flushSegment();
        }
        break;
        
      case VadState.trailing:
        _speechBuffer.add(frame);
        
        if (isSpeech) {
          // 语音恢复
          _vadState = VadState.speaking;
          _silenceFrameCount = 0;
          _speechFrameCount++;
        } else {
          _silenceFrameCount++;
          
          // 静音帧超过容忍度，判定语音段结束
          if (_silenceFrameCount >= _config.silenceFrameTolerance) {
            if (_speechFrameCount >= _config.minSpeechFrames) {
              _flushSegment();
            } else {
              // 太短，丢弃
              _speechBuffer.clear();
            }
            _vadState = VadState.idle;
            _speechFrameCount = 0;
            _silenceFrameCount = 0;
          }
        }
        break;
    }
  }

  /// 计算音频帧能量 (RMS)
  double _calculateEnergy(Uint8List frame) {
    if (frame.isEmpty) return 0.0;
    
    double sum = 0.0;
    for (int i = 0; i < frame.length; i += 2) {
      // 16bit little-endian 转 int16
      final sample = (frame[i] | (frame[i + 1] << 8));
      final normalized = sample / 32768.0; // 归一化到 [-1, 1]
      sum += normalized * normalized;
    }
    
    final rms = math.sqrt(sum / (frame.length / 2));
    return rms;
  }

  /// 刷新当前语音段
  void _flushSegment() {
    if (_speechBuffer.isEmpty) return;
    
    final segment = _concatFrames(_speechBuffer);
    _speechBuffer.clear();
    _onAudioSegment?.call(segment);
  }

  /// 拼接帧为完整段
  Uint8List _concatFrames(List<Uint8List> frames) {
    final totalLength = frames.fold(0, (sum, f) => sum + f.length);
    final result = Uint8List(totalLength);
    int offset = 0;
    for (final frame in frames) {
      result.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }
    return result;
  }

  /// 释放资源
  Future<void> dispose() async {
    await stop();
    _onAudioSegment = null;
    _rawBuffer.clear();
  }
}