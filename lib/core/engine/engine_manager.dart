/// 引擎管理器
/// 统一管理 ASR 和 MT 引擎的实例化、状态切换与销毁
/// 实现单例模式
library live_translate.core.engine.engine_manager;

import 'dart:developer';
import 'asr_engine.dart';
import 'mt_engine.dart';

/// 引擎类型枚举
enum EngineTypeEnum { asr, mt }

class EngineManager {
  EngineManager._internal();
  static final EngineManager _instance = EngineManager._internal();
  factory EngineManager() => _instance;
  
  // 注册的引擎工厂
  final Map<String, ASREngine Function()> _asrFactories = {};
  final Map<String, MTEngine Function()> _mtFactories = {};
  
  // 当前活跃的引擎实例
  ASREngine? _currentASR;
  MTEngine? _currentMT;
  
  // 引擎状态变更监听器
  final List<void Function(EngineTypeEnum, String?)> _listeners = [];
  
  /// 引擎类型枚举
  static const EngineTypeEnum asrType = EngineTypeEnum.asr;
  static const EngineTypeEnum mtType = EngineTypeEnum.mt;
  
  /// 当前 ASR 引擎
  ASREngine? get currentASR => _currentASR;
  
  /// 当前 MT 引擎
  MTEngine? get currentMT => _currentMT;
  
  /// 当前 ASR 引擎ID
  String? get currentASRId => _currentASR?.engineId;
  
  /// 当前 MT 引擎ID
  String? get currentMTId => _currentMT?.engineId;

  /// 最近一次 ASR 切换失败的原因（成功后清空）
  ///
  /// 为什么需要它：`switchASREngine` 失败时会把 `_currentASR` 置 null，
  /// 上层拿不到那个已销毁实例的 `lastError`，UI 只能显示「加载失败」。
  /// 有了这个字段，UI 才能告诉用户「到底缺什么」——
  /// 例如「原生库不在当前 ABI 的 APK 里」而不是笼统的失败。
  String? get lastASRError => _lastASRError;
  String? _lastASRError;

  /// 最近一次 MT 切换失败的原因（成功后清空）
  String? get lastMTError => _lastMTError;
  String? _lastMTError;
  
  /// 是否有活跃的 ASR 引擎
  bool get hasActiveASR => _currentASR?.isRunning == true;
  
  /// 是否有活跃的 MT 引擎
  bool get hasActiveMT => _currentMT?.isRunning == true;
  
  /// 注册 ASR 引擎工厂
  void registerASREngine(String engineId, ASREngine Function() factory) {
    _asrFactories[engineId] = factory;
  }
  
  /// 注册 MT 引擎工厂
  void registerMTEngine(String engineId, MTEngine Function() factory) {
    _mtFactories[engineId] = factory;
  }
  
  /// 获取已注册的 ASR 引擎列表
  List<String> getRegisteredASREngines() => _asrFactories.keys.toList();
  
  /// 获取已注册的 MT 引擎列表
  List<String> getRegisteredMTEngines() => _mtFactories.keys.toList();
  
  /// 创建 ASR 引擎实例
  ASREngine? createASREngine(String engineId) {
    final factory = _asrFactories[engineId];
    return factory?.call();
  }
  
  /// 创建 MT 引擎实例
  MTEngine? createMTEngine(String engineId) {
    final factory = _mtFactories[engineId];
    return factory?.call();
  }
  
  /// 切换 ASR 引擎
  /// [engineId] 目标引擎ID，为 null 时停止当前引擎
  /// [config] 初始化配置
  Future<bool> switchASREngine({
    String? engineId,
    Map<String, dynamic> config = const {},
  }) async {
    // 停止并释放当前引擎
    if (_currentASR != null) {
      try {
        await _currentASR!.stop();
        await _currentASR!.dispose();
      } catch (e, stack) {
        // 记录错误但继续切换
        log('Error disposing old ASR engine: $e\n$stack', name: 'EngineManager');
      }
      _currentASR = null;
    }
    
    if (engineId == null) {
      _notifyListeners(EngineTypeEnum.asr, null);
      return true;
    }
    
    // 创建新引擎
    final newEngine = createASREngine(engineId);
    if (newEngine == null) {
      log('ASR engine not found: $engineId', name: 'EngineManager');
      _notifyListeners(asrType, null);
      return false;
    }
    
    try {
      await newEngine.initialize(
        modelPath: config['modelPath'] as String?,
        language: config['language'] as String? ?? 'en',
        config: config,
      );
      _currentASR = newEngine;
      _lastASRError = null;
      _notifyListeners(EngineTypeEnum.asr, engineId);
      return true;
    } catch (e, stack) {
      log('Failed to initialize ASR engine $engineId: $e\n$stack', name: 'EngineManager');
      // 在 dispose 之前先把原因留下来：dispose 后实例状态可能被清空
      _lastASRError = _readEngineError(newEngine) ?? e.toString();
      await newEngine.dispose();
      _currentASR = null;
      _notifyListeners(asrType, null);
      return false;
    }
  }
  
  /// 切换 MT 引擎
  Future<bool> switchMTEngine({
    String? engineId,
    Map<String, dynamic> config = const {},
  }) async {
    // 停止并释放当前引擎
    if (_currentMT != null) {
      try {
        await _currentMT!.dispose();
      } catch (e, stack) {
        log('Error disposing old MT engine: $e\n$stack', name: 'EngineManager');
      }
      _currentMT = null;
    }
    
    if (engineId == null) {
      _notifyListeners(EngineTypeEnum.mt, null);
      return true;
    }
    
    // 创建新引擎
    final newEngine = createMTEngine(engineId);
    if (newEngine == null) {
      log('MT engine not found: $engineId', name: 'EngineManager');
      _notifyListeners(mtType, null);
      return false;
    }
    
    try {
      await newEngine.initialize(
        modelPath: config['modelPath'] as String?,
        sourceLang: config['sourceLang'] as String? ?? 'en',
        targetLang: config['targetLang'] as String? ?? 'ja',
        config: config,
      );
      _currentMT = newEngine;
      _lastMTError = null;
      _notifyListeners(EngineTypeEnum.mt, engineId);
      return true;
    } catch (e, stack) {
      log('Failed to initialize MT engine $engineId: $e\n$stack', name: 'EngineManager');
      _lastMTError = _readEngineError(newEngine) ?? e.toString();
      await newEngine.dispose();
      _currentMT = null;
      _notifyListeners(mtType, null);
      return false;
    }
  }

  /// 从引擎的 `getStatus()['error']` 里读出可读原因
  ///
  /// 约定：两个真实引擎在 `initialize()` 失败时都会把人类可读的原因
  /// 写进 `lastError` / `getStatus()['error']`，而抛出的异常本身可能是
  /// 底层 FFI 报错（`failed to open libllama.so`），对用户不友好。
  /// Mock 引擎没有这个字段，返回 null 由调用方回退到 `e.toString()`。
  String? _readEngineError(Object engine) {
    try {
      if (engine is ASREngine) {
        final status = engine.getStatus();
        final error = status['error'];
        if (error is String && error.trim().isNotEmpty) return error;
      } else if (engine is MTEngine) {
        final status = engine.getStatus();
        final error = status['error'];
        if (error is String && error.trim().isNotEmpty) return error;
      }
    } catch (_) {
      // getStatus 本身出错不影响降级流程
    }
    return null;
  }
  
  /// 启动当前 ASR 引擎
  Future<void> startASR({
    required Function(ASRResult) onResult,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    if (_currentASR == null) {
      throw StateError('No ASR engine selected');
    }
    await _currentASR!.start(onResult: onResult, onError: onError);
  }
  
  /// 停止当前 ASR 引擎
  Future<void> stopASR() async {
    if (_currentASR != null) {
      await _currentASR!.stop();
    }
  }
  
  /// 推送音频到当前 ASR 引擎
  Future<void> pushAudioToASR(List<int> audioData) async {
    if (_currentASR != null && _currentASR!.isRunning) {
      await _currentASR!.pushAudio(audioData);
    }
  }
  
  /// 使用当前 MT 引擎翻译
  Future<MTResult?> translateWithMT(String text) async {
    if (_currentMT == null) return null;
    return await _currentMT!.translate(text);
  }
  
  /// 使用当前 MT 引擎流式翻译
  Future<void> translateStreamWithMT({
    required String text,
    required Function(MTChunk) onChunk,
    required Function(MTResult) onComplete,
    required Function(Object error, StackTrace stack) onError,
  }) async {
    if (_currentMT == null) {
      onError(StateError('No MT engine selected'), StackTrace.current);
      return;
    }
    await _currentMT!.translateStream(
      text: text,
      onChunk: onChunk,
      onComplete: onComplete,
      onError: onError,
    );
  }
  
  /// 切换 ASR 语言
  Future<void> switchASRLanguage(String language) async {
    if (_currentASR != null) {
      await _currentASR!.switchLanguage(language);
    }
  }
  
  /// 切换 MT 语言对
  Future<void> switchMTLanguagePair(String sourceLang, String targetLang) async {
    if (_currentMT != null) {
      await _currentMT!.switchLanguagePair(sourceLang, targetLang);
    }
  }
  
  /// 释放所有引擎资源
  Future<void> disposeAll() async {
    if (_currentASR != null) {
      try {
        await _currentASR!.stop();
        await _currentASR!.dispose();
      } catch (e, stack) {
        log('Error disposing ASR: $e\n$stack', name: 'EngineManager');
      }
      _currentASR = null;
    }
    
    if (_currentMT != null) {
      try {
        await _currentMT!.dispose();
      } catch (e, stack) {
        log('Error disposing MT: $e\n$stack', name: 'EngineManager');
      }
      _currentMT = null;
    }
    
    _notifyListeners(EngineTypeEnum.asr, null);
    _notifyListeners(EngineTypeEnum.mt, null);
  }
  
  /// 获取所有引擎状态
  Map<String, dynamic> getAllStatus() {
    return {
      'asr': {
        'currentEngine': _currentASR?.engineId,
        'isInitialized': _currentASR?.isInitialized ?? false,
        'isRunning': _currentASR?.isRunning ?? false,
        'status': _currentASR?.getStatus(),
        'available': _asrFactories.keys.toList(),
      },
      'mt': {
        'currentEngine': _currentMT?.engineId,
        'isInitialized': _currentMT?.isInitialized ?? false,
        'isRunning': _currentMT?.isRunning ?? false,
        'status': _currentMT?.getStatus(),
        'available': _mtFactories.keys.toList(),
      },
    };
  }
  
  /// 添加状态变更监听器
  void addListener(void Function(EngineTypeEnum engineType, String? engineId) listener) {
    _listeners.add(listener);
  }
  
  /// 移除状态变更监听器
  void removeListener(void Function(EngineTypeEnum engineType, String? engineId) listener) {
    _listeners.remove(listener);
  }
  
  void _notifyListeners(EngineTypeEnum engineType, String? engineId) {
    for (final listener in _listeners) {
      try {
        listener(engineType, engineId);
      } catch (e) {
        log('Engine listener error: $e', name: 'EngineManager');
      }
    }
  }
}