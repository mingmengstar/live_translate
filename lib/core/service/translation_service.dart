/// 翻译服务
/// 协调 ASR 和 MT 引擎，处理完整的音频 -> 文本 -> 翻译 流程
/// 使用 Provider 进行状态管理
library live_translate.core.service.translation_service;

import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';
import 'package:live_translate/core/engine/engine.dart';
import 'package:live_translate/core/audio/audio_capture_service.dart';
import 'package:live_translate/core/model/model_storage.dart';
import 'package:live_translate/core/overlay/overlay_controller.dart';

class TranslationService extends ChangeNotifier {
  final EngineManager _engineManager = EngineManager();
  final AudioCaptureService _audioCapture = AudioCaptureService();
  final OverlayController _overlay = OverlayController.instance;
  
  // 状态
  bool _isServiceRunning = false;
  String _statusMessage = '就绪';
  String? _lastError;
  
  // 字幕缓冲区（用于悬浮窗显示）
  final List<SubtitleEntry> _subtitleBuffer = [];
  static const int _maxSubtitleEntries = 50;
  
  // 防抖定时器（悬浮窗更新节流 100ms）
  Timer? _debounceTimer;
  String _pendingSourceText = '';
  String _pendingTranslatedText = '';
  bool _pendingIsFinal = false;
  
  // 当前识别的临时文本（用于显示中间结果）
  String _currentPartialText = '';
  String _currentTranslatedPartial = '';
  // 语言设置
  String _asrLanguage = 'en';
  String _mtSourceLang = 'en';
  String _mtTargetLang = 'ja';
  
  // VAD 后端说明（初始化时写入，UI 可展示「当前用的是 Silero 还是能量 VAD」）
  String? _vadBackendNote;

  // 引擎选择说明（初始化时写入，说明为什么是 Mock / 真实引擎）
  String? _engineNote;
  
  
  // 获取器
  bool get isServiceRunning => _isServiceRunning;
  String get statusMessage => _statusMessage;
  String? get lastError => _lastError;
  List<SubtitleEntry> get subtitleBuffer => List.unmodifiable(_subtitleBuffer);
  String get currentPartialText => _currentPartialText;
  String get currentTranslatedPartial => _currentTranslatedPartial;
  String get asrLanguage => _asrLanguage;
  String get mtSourceLang => _mtSourceLang;
  String get mtTargetLang => _mtTargetLang;
  EngineManager get engineManager => _engineManager;

  /// VAD 后端说明（如「Silero VAD 已加载」/「未提供 Silero 模型，使用能量 VAD」）
  ///
  /// 初始化前为 null；初始化后由 [AudioCaptureService.vadBackendNote] 填充。
  String? get vadBackendNote => _vadBackendNote;

  /// 悬浮窗显示状态说明（失败时可直接展示给用户）
  String? _overlayNote;

  /// 悬浮窗是否已显示
  bool get isOverlayVisible => _overlay.isShowing;

  /// 悬浮窗状态说明（如「未获得悬浮窗权限」）
  String? get overlayNote => _overlayNote;

  /// 引擎选择说明（为何当前是 Mock / 真实引擎，如「模型缺失（2/6），使用 Mock 引擎」）
  String? get engineNote => _engineNote;
  
  /// 初始化服务：注册 Mock 引擎、初始化音频捕获
  Future<void> initialize() async {
    _updateStatus('正在初始化引擎...');
    
    // 注册 Mock 引擎（永远可用，作为兜底）
    _engineManager.registerASREngine('mock_asr', () => MockASR());
    _engineManager.registerMTEngine('mock_mt', () => MockMT());

    // 注册真实引擎（需要模型文件；initialize 失败会被 EngineManager 捕获并降级）
    _engineManager.registerASREngine(
      SherpaASREngine.kEngineId,
      () => SherpaASREngine(),
    );
    _engineManager.registerMTEngine(
      LlamaMTEngine.kEngineId,
      () => LlamaMTEngine(),
    );

    // ---- 选择「用哪套引擎」----
    //
    // 策略：模型齐全就优先真实引擎，缺任何一件就整体回 Mock。
    // 之所以「整体」而不是「ASR 真实 + MT Mock」混搭：
    // 混搭时真实 ASR 出的文本会被 MockMT 加上 `【日】` 前缀，
    // 看起来像「翻译坏了」，实际是 MT 是假的，排查成本很高。
    // 宁可两边都 Mock，状态明确。
    var asrEngineId = 'mock_asr';
    var mtEngineId = 'mock_mt';
    String? engineNote;

    try {
      final status = await ModelStorage.instance.inspect();
      if (!status.hasError && status.isReady) {
        asrEngineId = SherpaASREngine.kEngineId;
        mtEngineId = LlamaMTEngine.kEngineId;
        engineNote = '模型齐全，尝试加载真实引擎';
      } else if (!status.hasError) {
        engineNote = '模型缺失（${status.presentCount}/${status.totalCount}），'
            '使用 Mock 引擎';
      } else {
        engineNote = '模型检测失败，使用 Mock 引擎';
      }
    } catch (e) {
      engineNote = '模型检测异常，使用 Mock 引擎: $e';
      log('[TranslationService] 模型检测失败: $e', name: 'TranslationService');
    }

    // 切换 ASR：真实引擎初始化失败时自动回落 Mock
    var asrOk = await _engineManager.switchASREngine(
      engineId: asrEngineId,
      config: {'language': _asrLanguage},
    );
    if (!asrOk && asrEngineId != 'mock_asr') {
      // switchASREngine 失败时已把 _currentASR 置 null，
      // 但失败原因由 EngineManager.lastASRError 保留了，能给出具体说明。
      final reason = _summarizeReason(_engineManager.lastASRError);
      engineNote = '真实 ASR 加载失败，已降级 Mock'
          '${reason == null ? '' : '（$reason）'}';
      asrOk = await _engineManager.switchASREngine(
        engineId: 'mock_asr',
        config: {'language': _asrLanguage},
      );
    }

    // 切换 MT：同样失败回落 Mock
    var mtOk = await _engineManager.switchMTEngine(
      engineId: mtEngineId,
      config: {
        'sourceLang': _mtSourceLang,
        'targetLang': _mtTargetLang,
      },
    );
    if (!mtOk && mtEngineId != 'mock_mt') {
      // 这里最常见的原因就是「当前 ABI 的 APK 里没有 llama.cpp 原生库」，
      // 旧文案只说「加载失败」，用户完全无从判断，必须带出具体原因。
      final reason = _summarizeReason(_engineManager.lastMTError);
      engineNote = '真实 MT 加载失败，已降级 Mock'
          '${reason == null ? '' : '（$reason）'}';
      mtOk = await _engineManager.switchMTEngine(
        engineId: 'mock_mt',
        config: {
          'sourceLang': _mtSourceLang,
          'targetLang': _mtTargetLang,
        },
      );
    }

    _engineNote = engineNote;
    // 初始化音频捕获服务
    //
    // 必须先解析 Silero VAD 模型路径再传进去，否则 VAD 会永远走能量后端：
    // 下游 vad_types.dart 的 sileroModelPath 为 null 时，
    // vad_isolate_worker.dart 的 `preferSilero && sileroModelPath != null`
    // 永远不成立，模型哪怕下载好了也不会被加载。
    // resolveVadModelPath() 在模型缺失时返回 null，此时自动降级能量 VAD，
    // 不阻塞主流程。
    String? vadModelPath;
    try {
      vadModelPath = await ModelStorage.instance.resolveVadModelPath();
    } catch (e) {
      // 平台通道不可用（单元测试 / 非 Android 环境）时不要中断初始化
      log(
        '[TranslationService] resolveVadModelPath 失败: $e',
        name: 'TranslationService',
      );
    }

    await _audioCapture.initialize(
      sileroModelPath: vadModelPath,
      onAudioSegment: _onAudioSegment,
    );

    // 把 VAD 后端结论暴露给 UI（首页 / 控制台可展示当前用的是 Silero 还是能量）
    _vadBackendNote = _audioCapture.vadBackendNote;
    log(
      '[TranslationService] VAD 后端=${_audioCapture.vadBackend} '
      'model=$vadModelPath note=$_vadBackendNote',
      name: 'TranslationService',
    );

    if (asrOk && mtOk) {
      // 状态文案要反映真实引擎，不能固定写「Mock 模式」——
      // 否则下载完全部模型、真实引擎已加载时，UI 还在说 Mock，
      // 用户会以为下载没生效。
      final isReal = _engineManager.currentASRId != 'mock_asr' &&
          _engineManager.currentMTId != 'mock_mt';
      _updateStatus(isReal ? '引擎就绪（真实引擎）' : '引擎就绪 (Mock 模式)');
      _lastError = null;
    } else {
      _lastError = '引擎初始化失败';
      _updateStatus('初始化失败');
    }

    // 监听引擎变更
    _engineManager.addListener(_onEngineChanged);

    // 预热悬浮窗引擎
    //
    // 冷启动 overlayMain 大约要 5s（插件文档也提到这一点），
    // 如果等用户点「开始」才创建，会出现「点了开始、几秒后字幕条才冒出来」
    // 的体感延迟。这里在 App 初始化阶段就建好引擎（此时用户还在首页），
    // 点开始时是热的。失败不影响功能，warmUp() 内部已吞掉异常。
    unawaited(_overlay.warmUp());
  }

  /// 音频段回调（来自 VAD）
  void _onAudioSegment(Uint8List audioData) {
    if (_isServiceRunning) {
      _engineManager.pushAudioToASR(audioData);
    }
  }

  /// 把引擎的失败原因压成一句能塞进 UI 的短文本
  ///
  /// 引擎写进 `lastError` 的原因往往很长（含底层 FFI 报错、路径、堆栈提示），
  /// 直接拼进 `engineNote` 会把界面撑爆。这里只保留「最关键的那一层含义」。
  ///
  /// 识别优先级：
  /// 1. 原生库缺失（ABI 不匹配）—— 这是当前最可能的原因；
  /// 2. 模型文件缺失；
  /// 3. 其余情况截断原文。
  String? _summarizeReason(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final text = raw.trim();

    if (text.contains('libllama.so') ||
        text.contains('libmtmd.so') ||
        text.contains('原生库')) {
      // 用户看到这句就能自己去下对应架构的包，或换 arm64 设备
      return '当前 APK 架构不含 llama.cpp 原生库，请用 arm64-v8a 版本';
    }
    if (text.contains('未检测到翻译模型') || text.contains('*.gguf')) {
      return '未检测到翻译模型（*.gguf）';
    }
    if (text.contains('超时') || text.contains('Timeout')) {
      return '加载超时';
    }
    if (text.contains('out of memory') || text.contains('OOM')) {
      return '内存不足';
    }

    // 兜底：截到 60 字，避免把整段堆栈塞进状态栏
    const maxLen = 60;
    return text.length <= maxLen ? text : '${text.substring(0, maxLen)}…';
  }

  void _onEngineChanged(EngineTypeEnum engineType, String? engineId) {
    final typeStr = engineType == EngineTypeEnum.asr ? 'ASR' : 'MT';
    _updateStatus(engineId != null ? '$typeStr 引擎已切换: $engineId' : '$typeStr 引擎已停止');
    notifyListeners();
  }
  
  /// 启动翻译服务
  Future<void> startService() async {
    if (_isServiceRunning) return;
    
    _updateStatus('正在启动服务...');
    _clearError();
    
    try {
      // 启动 ASR
      await _engineManager.startASR(
        onResult: _onASRResult,
        onError: _onASRError,
      );
      
      // 启动音频捕获
      await _audioCapture.start();

      _isServiceRunning = true;
      _subtitleBuffer.clear();

      // 显示悬浮字幕窗口
      //
      // 顺序很重要：必须放在「音频真的开始流」之后。
      // 否则用户点了开始、但屏幕录制授权被拒（start() 已抛异常走到 catch），
      // 悬浮窗却已经挂出来了 —— 屏幕上留一条永远「等待语音输入...」的黑条。
      await _syncOverlayWithServiceState();

      _updateStatus('服务运行中...');
      notifyListeners();
    } catch (e, stack) {
      _lastError = '启动失败: $e';
      _updateStatus('启动失败');
      log('TranslationService start error: $e\n$stack', name: 'TranslationService');
      // 启动失败时确保不会遗留一个假运行的悬浮窗
      await _overlay.hide();
      _overlayNote = null;
      notifyListeners();
    }
  }

  /// 把悬浮窗状态同步到「服务是否运行」
  ///
  /// 悬浮窗单独失败**不应该**让翻译服务失败：字幕条是展示层，
  /// 音频与翻译是核心链路。所以这里只记录原因，不抛出。
  Future<void> _syncOverlayWithServiceState() async {
    if (!_isServiceRunning) {
      await _overlay.hide();
      _overlayNote = null;
      return;
    }

    final result = await _overlay.show();
    _overlayNote = result.ok ? null : result.reason;
    if (!result.ok) {
      log(
        '[TranslationService] 悬浮窗未能显示: ${result.reason}',
        name: 'TranslationService',
      );
    }
  }

  /// 手动重试显示悬浮窗（供 UI 的「悬浮窗未显示」提示条调用）
  ///
  /// 典型场景：用户点了开始，但悬浮窗权限此前被拒；
  /// 去系统设置里授权后回到 App，点一下即可补上，不必停止再启动服务。
  Future<OverlayShowResult> retryOverlay() async {
    if (!_isServiceRunning) {
      return const OverlayShowResult(
        ok: false,
        reason: '翻译服务未运行，悬浮窗无需显示',
      );
    }
    final result = await _overlay.show();
    _overlayNote = result.ok ? null : result.reason;
    notifyListeners();
    return result;
  }
  
  /// 停止翻译服务
  Future<void> stopService() async {
    if (!_isServiceRunning) return;
    
    _updateStatus('正在停止服务...');
    
    try {
      // 先关悬浮窗：停止过程中引擎会清空字幕，
      // 若窗口还挂着会闪一下空的「等待语音输入...」再消失。
      await _overlay.hide();
      _overlayNote = null;

      await _engineManager.stopASR();
      
      // 停止音频捕获
      await _audioCapture.stop();
      
      _isServiceRunning = false;
      _currentPartialText = '';
      _currentTranslatedPartial = '';
      _debounceTimer?.cancel();
      _updateStatus('服务已停止');
      notifyListeners();
    } catch (e, stack) {
      _lastError = '停止失败: $e';
      _updateStatus('停止失败');
      debugPrint('TranslationService stop error: $e\n$stack');
      notifyListeners();
    }
  }
  
  /// 切换服务运行状态
  Future<void> toggleService() async {
    if (_isServiceRunning) {
      await stopService();
    } else {
      await startService();
    }
  }
  
  /// 推送音频数据到 ASR
  Future<void> pushAudio(List<int> audioData) async {
    if (!_isServiceRunning) return;
    await _engineManager.pushAudioToASR(audioData);
  }
  
  /// ASR 结果回调
  void _onASRResult(ASRResult result) {
    log('[TranslationService] ASR: ${result.text} (final: ${result.isFinal})', name: 'TranslationService');
    
    // 更新当前部分文本
    _currentPartialText = result.text;
    
    if (result.isFinal) {
      // 最终结果：触发翻译
      _currentPartialText = '';
      _translateText(result.text);
    } else {
      // 中间结果：直接显示（不翻译，避免频繁调用 MT）
      notifyListeners();
    }
  }
  
  /// ASR 错误回调
  void _onASRError(Object error, StackTrace stack) {
    _lastError = 'ASR 错误: $error';
    _updateStatus('ASR 出错');
    log('[TranslationService] ASR Error: $error\n$stack', name: 'TranslationService');
    notifyListeners();
  }
  
  /// 翻译文本
  Future<void> _translateText(String text) async {
    if (text.trim().isEmpty) return;
    
    try {
      await _engineManager.translateStreamWithMT(
        text: text,
        onChunk: (chunk) {
          _currentTranslatedPartial = chunk.text;
          
          // 防抖更新悬浮窗（100ms 节流）
          _scheduleDebouncedUpdate(
            sourceText: text,
            translatedText: chunk.text,
            isFinal: chunk.isFinal,
          );
        },
        onComplete: (result) {
          _currentTranslatedPartial = '';
          _addSubtitleEntry(
            sourceText: result.sourceText,
            translatedText: result.translatedText,
            isFinal: true,
          );
        },
        onError: (error, stack) {
          _lastError = '翻译错误: $error';
          _currentTranslatedPartial = '';
          log('[TranslationService] MT Error: $error\n$stack', name: 'TranslationService');
          notifyListeners();
        },
      );
    } catch (e, stack) {
      _lastError = '翻译启动失败: $e';
      log('[TranslationService] Translate error: $e\n$stack', name: 'TranslationService');
      notifyListeners();
    }
  }
  
  /// 调度防抖更新（100ms 节流，避免高频渲染崩溃）
  void _scheduleDebouncedUpdate({
    required String sourceText,
    required String translatedText,
    required bool isFinal,
  }) {
    _pendingSourceText = sourceText;
    _pendingTranslatedText = translatedText;
    _pendingIsFinal = isFinal;
    
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      _addSubtitleEntry(
        sourceText: _pendingSourceText,
        translatedText: _pendingTranslatedText,
        isFinal: _pendingIsFinal,
      );
      // 通过 FlutterScreenOverlay.shareData() 发送给悬浮窗
      _sendToOverlay();
    });
  }
  
  /// 添加字幕条目到缓冲区
  void _addSubtitleEntry({
    required String sourceText,
    required String translatedText,
    required bool isFinal,
  }) {
    final entry = SubtitleEntry(
      sourceText: sourceText,
      translatedText: translatedText,
      timestamp: DateTime.now(),
      isFinal: isFinal,
      sourceLang: _mtSourceLang,
      targetLang: _mtTargetLang,
    );
    
    _subtitleBuffer.insert(0, entry);
    
    // 限制缓冲区大小
    if (_subtitleBuffer.length > _maxSubtitleEntries) {
      _subtitleBuffer.removeRange(_maxSubtitleEntries, _subtitleBuffer.length);
    }
    
    notifyListeners();
  }
  
  /// 发送数据到悬浮窗（通过 FlutterScreenOverlay.shareData）
  void _sendToOverlay() {
    try {
      FlutterScreenOverlay.shareData({
        'sourceText': _pendingSourceText,
        'translatedText': _pendingTranslatedText,
        'isFinal': _pendingIsFinal,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      log('[Overlay] Sent: source="$_pendingSourceText", translated="$_pendingTranslatedText"', name: 'TranslationService');
    } catch (e) {
      log('[Overlay] Send failed: $e', name: 'TranslationService');
    }
  }
  
  /// 切换 ASR 语言
  Future<void> setASRLanguage(String language) async {
    _asrLanguage = language;
    await _engineManager.switchASRLanguage(language);
    notifyListeners();
  }
  
  /// 切换 MT 语言对
  Future<void> setMTLanguagePair(String sourceLang, String targetLang) async {
    _mtSourceLang = sourceLang;
    _mtTargetLang = targetLang;
    await _engineManager.switchMTLanguagePair(sourceLang, targetLang);
    notifyListeners();
  }
  
  /// 切换引擎（用于后续接入真实引擎）
  Future<bool> switchASREngine(String engineId, {Map<String, dynamic> config = const {}}) async {
    _updateStatus('正在切换 ASR 引擎...');
    final ok = await _engineManager.switchASREngine(
      engineId: engineId,
      config: {'language': _asrLanguage, ...config},
    );
    if (ok) _updateStatus('ASR 引擎已切换: $engineId');
    return ok;
  }
  
  Future<bool> switchMTEngine(String engineId, {Map<String, dynamic> config = const {}}) async {
    _updateStatus('正在切换 MT 引擎...');
    final ok = await _engineManager.switchMTEngine(
      engineId: engineId,
      config: {
        'sourceLang': _mtSourceLang,
        'targetLang': _mtTargetLang,
        ...config,
      },
    );
    if (ok) _updateStatus('MT 引擎已切换: $engineId');
    return ok;
  }
  
  void _updateStatus(String message) {
    _statusMessage = message;
    notifyListeners();
  }
  
  void _clearError() {
    _lastError = null;
  }
  
  /// 清空字幕缓冲区
  void clearSubtitles() {
    _subtitleBuffer.clear();
    notifyListeners();
  }
  
  @override
  void dispose() {
    _debounceTimer?.cancel();
    _engineManager.removeListener(_onEngineChanged);
    // 先同步关窗（不 await，dispose 是同步的），
    // 避免 App 退出后系统里残留一条无主的悬浮字幕条。
    unawaited(_overlay.hide());
    stopService();
    _engineManager.disposeAll();
    _audioCapture.dispose();
    super.dispose();
  }
}

/// 字幕条目数据类
class SubtitleEntry {
  final String sourceText;
  final String translatedText;
  final DateTime timestamp;
  final bool isFinal;
  final String sourceLang;
  final String targetLang;
  
  const SubtitleEntry({
    required this.sourceText,
    required this.translatedText,
    required this.timestamp,
    required this.isFinal,
    required this.sourceLang,
    required this.targetLang,
  });
  
  @override
  String toString() =>
      'SubtitleEntry($sourceLang->$targetLang: "$sourceText" -> "$translatedText", final: $isFinal)';
}