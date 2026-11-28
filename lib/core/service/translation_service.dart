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
import 'package:live_translate/core/model/model_catalog.dart';
import 'package:live_translate/core/model/model_storage.dart';
import 'package:live_translate/core/overlay/overlay_controller.dart';
import 'package:live_translate/core/overlay/overlay_protocol.dart';
import 'package:live_translate/core/overlay/overlay_settings.dart';
import 'package:live_translate/core/service/app_settings.dart';

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

  // ---- v0.8.0 流式翻译状态 ----
  //
  // 这套状态是「实时字幕」的核心。StreamRevise 模型是无状态的，
  // 由调用方（也就是这里）维护「当前句译文链」与「前文上下文」。
  //
  // 旧实现的致命问题：只在 `isFinal` 时才翻译。等一整句说完再翻，
  // 既不实时，也让 StreamRevise 模型的「前缀保留 + 修订」能力完全失效。

  /// 当前句的累计识别文本（ASR 最后一次上报的版本）
  String _sentenceSource = '';

  /// 当前句**上一版原文**（上一轮 ASR 的识别文本）
  ///
  /// 只给 **Hy-MT2** 模板的 `Previous version of the current source:` 用。
  /// Hy-MT3 模板刻意不传上一版原文（见 `LlamaMTEngine` 的模板注释），
  /// 渲染时会忽略它。
  ///
  /// 必须真的存「上一轮识别文本」：拿译文顶替会让模型以为
  /// 「上一版原文就是这段译文」，前缀对照从输入层就是错的。
  String _sentencePreviousSource = '';

  /// 当前句**上一版译文**
  ///
  /// 这是 StreamRevise 模型最关键的输入：它靠比对这个值来决定
  /// 沿用哪段前缀、改写哪一段。必须每轮翻译后更新。
  String _sentenceTranslation = '';

  /// 已定稿句子的原文（用于「前文上下文」，最多 [maxContextSentences] 句）
  final List<String> _recentSources = [];

  /// 前文上下文最多保留几句（模型卡建议 5 句）
  static const int maxContextSentences = 5;

  /// 当前句是否已经定稿（定稿后不再接受新文本，直到下一句开始）
  bool _sentenceFinalized = false;

  /// 是否正在翻译（避免同一时刻堆积多个推理请求）
  bool _isTranslating = false;
  /// 是否正在翻译（诊断 / 测试用）
  bool get isTranslating => _isTranslating;

  /// 当前这一次翻译的代号（每次发起推理自增）
  ///
  /// 用来丢弃「已被新识别结果取代的那次推理」迟到的 token。
  /// 没有它，旧推理的尾部 token 会把新推理刚写上的译文又盖回去，
  /// 屏幕上的字幕会来回跳。
  int _mtRunId = 0;

  /// 最近一次已推给界面的「流式部分译文」
  ///
  /// 只用于去重：token 级回调里会有大量重复内容（StreamRevise 模型
  /// 大段沿用上一版译文时尤其明显），不比对就会产生大量无意义的
  /// setState 与悬浮窗消息。
  String _lastStreamedPartial = '';

  /// 语言设置
  String _asrLanguage = 'en';
  String _mtSourceLang = 'en';
  String _mtTargetLang = 'ja';

  /// 当前选用的翻译模型（决定提示词模板与内存需求）
  MtModelVariant _mtModelVariant = MtModelVariant.hyMt3StreamRevise;

  /// 当前选用的翻译模型
  MtModelVariant get mtModelVariant => _mtModelVariant;
  
  // VAD 后端说明（初始化时写入，UI 可展示「当前用的是 Silero 还是能量 VAD」）
  String? _vadBackendNote;
  
  // 引擎选择说明（初始化时写入，说明为什么是 Mock / 真实引擎）
  String? _engineNote;

  // ---- 悬浮窗反向控制 ----
  //
  // 订阅插件那条双向通道里「overlay → 主 App」方向的消息。
  // 不订阅的话，悬浮窗上的按钮点了只会改它自己的本地快照，
  // 主 App 完全不知道 —— 表现就是「点了隐藏，窗口还在」。
  StreamSubscription<dynamic>? _overlayCommandSub;

  /// 用户是否主动收起了悬浮窗（服务仍在跑）
  ///
  /// 与 `_overlay.isShowing` 分开记：
  /// `isShowing` 是「窗口当前在不在」，这个是「用户想不想让它显示」。
  /// 没有这个区别的话，用户点「收起」后只要有任何一次
  /// `_syncOverlayWithServiceState()` 就会被重新拉出来，等于收起按钮失效。
  bool _overlayDismissedByUser = false;
  
  
  
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

  /// 悬浮窗失败的机器可读错误码（`PERMISSION` / `SERVICE_START` /
  /// `NOT_ATTACHED` / `EXCEPTION` / `IN_FLIGHT`，见 [OverlayShowResult.code]）
  ///
  /// 为什么要单独存一份而不是只留 [overlayNote]：
  /// `reason` 是给人看的中文长句，真机复测时无法凭它判断到底是"权限没给"、
  /// "服务被后台启动限制挡住"，还是"服务起来了但视图没挂上"——
  /// 这三种的修法完全不同。把 code 一并透出，才能一眼定位。
  String? _overlayErrorCode;

  /// 悬浮窗是否已显示
  bool get isOverlayVisible => _overlay.isShowing;

  /// 悬浮窗状态说明（如「未获得悬浮窗权限」）
  String? get overlayNote => _overlayNote;

  /// 悬浮窗失败错误码（成功 / 未尝试时为 null）
  String? get overlayErrorCode => _overlayErrorCode;

  /// 把 [OverlayShowResult] 记录成「可展示给用户的说明 + 错误码」
  ///
  /// 收敛成一个私有方法，避免 4 处调用点各自写一遍 `ok ? null : reason`，
  /// 漏掉 code 的赋值（这正是 BUG-2 排查困难的直接原因）。
  void _applyOverlayResult(OverlayShowResult result) {
    _overlayNote = result.ok ? null : result.reason;
    _overlayErrorCode = result.ok ? null : result.code;
  }

  /// 清空悬浮窗的失败记录（窗口正常关闭 / 服务停止时调用）
  ///
  /// 两个字段必须一起清：只清 `_overlayNote` 会残留一个错误码，
  /// 之后界面显示「未显示（NOT_ATTACHED）」这种自相矛盾的状态。
  void _clearOverlayIssue() {
    _overlayNote = null;
    _overlayErrorCode = null;
  }

  /// 当前悬浮窗显示设置（字号 / 透明度 / 位置）
  OverlaySettings get overlaySettings => OverlaySettingsStore.instance.current;

  /// 用户是否主动收起了悬浮窗（服务仍在运行）
  bool get isOverlayDismissedByUser => _overlayDismissedByUser;

  /// 引擎选择说明（为何当前是 Mock / 真实引擎，如「模型缺失（2/6），使用 Mock 引擎」）
  String? get engineNote => _engineNote;
  
  /// 重新加载引擎（模型下载完成后热切换用）
  ///
  /// ## 为什么需要它
  ///
  /// 模型下载是「运行中」发生的：用户可能在服务已启动、甚至正在看着
  /// 「未加载」状态时去下载模型。下完之后如果只能重启 App 才生效，
  /// 用户会以为「下载了但没用」。
  ///
  /// ## 与 [initialize] 的区别
  ///
  /// - `initialize()` 是**冷启动**：注册工厂 + 选引擎 + 初始化音频/VAD/悬浮窗。
  ///   重复调用会重复 `_engineManager.addListener`（监听器越加越多）。
  /// - `reloadEngines()` 是**热重载**：只做「释放旧引擎 → 重新注册 → 重新选」，
  ///   不动音频捕获、不动悬浮窗、不重复订阅。
  ///
  /// 返回本次是否成功切到了真实引擎（false 表示仍然缺模型 / 加载失败，
  /// 具体原因见 [engineNote]）。
  ///
  /// 若服务正在运行，会在重载前后自动「停 → 起」，否则旧引擎的 isolate
  /// 已被释放、新引擎还没 start，音频会直接丢进一个不存在的引擎。
  Future<bool> reloadEngines() async {
    final wasRunning = _isServiceRunning;

    _updateStatus('正在重新加载引擎...');

    // 停：必须在 disposeAll 之前。否则 dispose 掉的是正在吐结果的实例。
    if (wasRunning) {
      try {
        await stopService();
      } catch (e) {
        log('[TranslationService] 重载前停止服务失败: $e',
            name: 'TranslationService');
      }
    }

    // 释放：先停 ASR 再释放，避免 isolate 还在往已销毁的端口发消息
    await _engineManager.disposeAll();

    // 重新注册（disposeAll 只清实例，工厂表其实还在，这里显式重注册
    // 保证「从没 initialize 过」的路径也能用）
    _engineManager.registerASREngine(
      SherpaASREngine.kEngineId,
      () => SherpaASREngine(),
    );
    _engineManager.registerMTEngine(
      LlamaMTEngine.kEngineId,
      () => LlamaMTEngine(),
    );

    // 重新判定模型是否齐全
    String? engineNote;
    var modelsReady = false;
    try {
      final status = await ModelStorage.instance.inspect();
      if (status.hasError) {
        engineNote = '模型检测失败：${status.error}';
      } else if (status.isReady) {
        modelsReady = true;
        engineNote = '模型齐全，正在加载真实引擎';
      } else {
        engineNote = '模型缺失（${status.presentCount}/${status.totalCount}），'
            '请先到「模型管理」下载';
      }
    } catch (e) {
      engineNote = '模型检测异常：$e';
      log('[TranslationService] 重载时模型检测失败: $e',
          name: 'TranslationService');
    }

    if (!modelsReady) {
      _engineNote = engineNote;
      _updateStatus('等待模型');
      _lastError = null;
      notifyListeners();
      return false;
    }

    var asrOk = false;
    var mtOk = false;

    asrOk = await _engineManager.switchASREngine(
      engineId: SherpaASREngine.kEngineId,
      config: {'language': _asrLanguage},
    );
    if (!asrOk) {
      final reason = _summarizeReason(_engineManager.lastASRError);
      engineNote = '真实 ASR 加载失败${reason == null ? '' : '（$reason）'}';
    }

    mtOk = await _engineManager.switchMTEngine(
      engineId: LlamaMTEngine.kEngineId,
      config: {
        'sourceLang': _mtSourceLang,
        'targetLang': _mtTargetLang,
        'promptStyle': _currentMtPromptStyleName,
      },
    );
    if (!mtOk) {
      final reason = _summarizeReason(_engineManager.lastMTError);
      engineNote = '真实 MT 加载失败${reason == null ? '' : '（$reason）'}';
    }

    _engineNote = engineNote;

    // VAD 模型可能是这次刚下的：重新解析一次路径
    try {
      final vadPath = await ModelStorage.instance.resolveVadModelPath();
      _vadBackendNote = vadPath == null
          ? '未提供 Silero 模型，使用能量 VAD'
          : 'Silero VAD 可用';
      await _audioCapture.initialize(
        sileroModelPath: vadPath,
        onAudioChunk: _onAudioChunk,
      );
    } catch (e) {
      log('[TranslationService] 重载 VAD 失败: $e', name: 'TranslationService');
    }

    final ok = asrOk && mtOk;
    if (ok) {
      _updateStatus('引擎就绪（真实引擎）');
      _lastError = null;
    } else {
      _lastError = engineNote;
      _updateStatus('初始化失败');
    }
    notifyListeners();

    // 起：只有在原来就在跑、且这次重载成功时才恢复
    if (wasRunning && ok) {
      try {
        await startService();
      } catch (e) {
        log('[TranslationService] 重载后重启服务失败: $e',
            name: 'TranslationService');
      }
    }

    return ok;
  }

  /// 当前 MT 提示词模板（供 reloadEngines 传给引擎）
  String get _currentMtPromptStyleName =>
      ModelCatalog.mtSpec(_mtModelVariant).promptStyle.name;

  // ---------------------------------------------------------------------------
  // 引擎健康检查（v0.6.0）
  // ---------------------------------------------------------------------------

  /// 健康检查计时器
  Timer? _healthCheckTimer;

  /// 健康检查周期
  ///
  /// 30s：够快发现「引擎静默死了」，又不会让 `getStatus()` 频繁打断推理。
  /// 检查本身只是读字段，但真实引擎的 `getStatus()` 会走 FFI 查询，
  /// 太频繁会拖慢 decode。
  static const Duration healthCheckInterval = Duration(seconds: 30);

  /// 连续多少次健康检查失败后触发重载
  ///
  /// 不用「一次失败就重载」：切引擎 / 刚 start 的瞬间状态本来就是中间态，
  /// 一次误判会把正在正常运行的引擎打断。连续 2 次（约 1 分钟）
  /// 才是真的死了。
  static const int healthFailureThreshold = 2;

  int _consecutiveHealthFailures = 0;

  /// 连续失败次数（诊断用）
  int get consecutiveHealthFailures => _consecutiveHealthFailures;

  /// 最近一次健康检查的结论说明（UI 可展示）
  String? _healthNote;
  String? get healthNote => _healthNote;

  /// 启动周期性健康检查
  ///
  /// 检查内容（任一不满足即计一次失败）：
  /// - 服务在跑，但 ASR 引擎的 `isRunning` 是 false（说明 isolate 已经死了）；
  /// - 服务在跑，但 MT 引擎 `isInitialized` 是 false。
  ///
  /// 达到 [healthFailureThreshold] 次失败后自动调 [reloadEngines]。
  /// 重载本身失败也不会无限循环：重载会把计数清零，
  /// 若模型真的没了，`reloadEngines` 会返回 false 并保持「等待模型」状态。
  void startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(healthCheckInterval, (_) {
      // 未 await：定时器回调不能是 async，且检查本身不抛异常
      unawaited(runHealthCheckOnce());
    });
  }

  /// 停止周期性健康检查
  void stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  /// 执行一次健康检查（可被测试直接调用）
  Future<bool> runHealthCheckOnce() async {
    if (!_isServiceRunning) {
      _consecutiveHealthFailures = 0;
      return true;
    }

    final asr = _engineManager.currentASR;
    final mt = _engineManager.currentMT;

    // 没有引擎：说明本来就处于「等待模型」，不是健康问题
    if (asr == null && mt == null) {
      _consecutiveHealthFailures = 0;
      return true;
    }

    String? problem;
    if (asr != null && !asr.isRunning) {
      problem = 'ASR 引擎已停止响应';
    } else if (asr != null && !asr.isInitialized) {
      problem = 'ASR 引擎未初始化';
    } else if (mt != null && !mt.isInitialized) {
      problem = 'MT 引擎未初始化';
    }

    if (problem == null) {
      _consecutiveHealthFailures = 0;
      _healthNote = null;
      return true;
    }

    _consecutiveHealthFailures++;
    _healthNote = '$problem（连续 $_consecutiveHealthFailures 次）';
    log(
      '[TranslationService] 健康检查失败: $_healthNote',
      name: 'TranslationService',
    );
    notifyListeners();

    if (_consecutiveHealthFailures >= healthFailureThreshold) {
      _consecutiveHealthFailures = 0;
      log('[TranslationService] 连续失败达阈值，自动重载引擎',
          name: 'TranslationService');
      unawaited(reloadEngines());
      return false;
    }
    return false;
  }

  /// 初始化服务：注册真实引擎、初始化音频捕获
  ///
  /// ## v0.5.0：为什么不再注册 / 不自动降级到 Mock
  ///
  /// 旧实现会在模型缺失或真实引擎加载失败时**静默**切到 `MockASR`/`MockMT`。
  /// 这在真机上是灾难性的：
  ///
  /// - Mock ASR 每 3 秒吐一句预置的假文本，Mock MT 只加 `【日】` 前缀；
  /// - 用户看到字幕条「有内容」，会以为识别和翻译都在工作，
  ///   实际上一句真实语音都没被处理；
  /// - 更糟的是 `engineNote` 只在主界面某一行小字里提一句，
  ///   而悬浮窗上完全看不出这是假数据。
  ///
  /// 现在：**没有模型就是没有模型**。初始化会明确失败并把原因写进
  /// [engineNote] / [lastError]，UI 直接显示「缺少模型，请先下载」。
  /// 这样用户点「开始」之前就知道能不能用，不会对着假字幕调试半天。
  ///
  /// `MockASR` / `MockMT` 类仍然保留在 `lib/core/engine/mock_*.dart`，
  /// 但**只被 `test/` 引用**（验证引擎接口契约），不参与运行时注册，
  /// release 构建会把它们 tree-shake 掉。
  Future<void> initialize() async {
    _updateStatus('正在初始化引擎...');

    // 0) 恢复持久化的语言 / 模型选择
    //
    // 必须在选引擎**之前**：`switchASREngine` 要拿 `_asrLanguage` 当参数，
    // 晚一步就会出现「界面显示 en→zh，实际引擎按 en→ja 跑」的错位。
    await AppSettingsStore.instance.load();
    _asrLanguage = AppSettingsStore.instance.asrLanguage;
    _mtSourceLang = AppSettingsStore.instance.mtSourceLang;
    _mtTargetLang = AppSettingsStore.instance.mtTargetLang;
    _mtModelVariant = AppSettingsStore.instance.mtVariant;

    // 注册真实引擎（需要模型文件；initialize 失败会被 EngineManager 捕获）
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
    // 只有模型齐全才尝试加载真实引擎。缺任何一件都保持「未加载」状态，
    // 由 UI 引导用户去「模型管理」下载，而不是偷偷跑假数据。
    String? engineNote;
    var modelsReady = false;

    try {
      final status = await ModelStorage.instance.inspect();
      if (status.hasError) {
        engineNote = '模型检测失败：${status.error}';
      } else if (status.isReady) {
        modelsReady = true;
        engineNote = '模型齐全，正在加载真实引擎';
      } else {
        engineNote = '模型缺失（${status.presentCount}/${status.totalCount}），'
            '请先到「模型管理」下载';
      }
    } catch (e) {
      engineNote = '模型检测异常：$e';
      log('[TranslationService] 模型检测失败: $e', name: 'TranslationService');
    }

    var asrOk = false;
    var mtOk = false;

    if (modelsReady) {
      asrOk = await _engineManager.switchASREngine(
        engineId: SherpaASREngine.kEngineId,
        config: {'language': _asrLanguage},
      );
      if (!asrOk) {
        // switchASREngine 失败时已把 _currentASR 置 null，
        // 但失败原因由 EngineManager.lastASRError 保留了，能给出具体说明。
        final reason = _summarizeReason(_engineManager.lastASRError);
        engineNote = '真实 ASR 加载失败'
            '${reason == null ? '' : '（$reason）'}';
      }

      mtOk = await _engineManager.switchMTEngine(
        engineId: LlamaMTEngine.kEngineId,
        config: {
          'sourceLang': _mtSourceLang,
          'targetLang': _mtTargetLang,
          'promptStyle': _currentMtPromptStyleName,
        },
      );
      if (!mtOk) {
        // 这里最常见的原因就是「当前 ABI 的 APK 里没有 llama.cpp 原生库」，
        // 旧文案只说「加载失败」，用户完全无从判断，必须带出具体原因。
        final reason = _summarizeReason(_engineManager.lastMTError);
        engineNote = '真实 MT 加载失败'
            '${reason == null ? '' : '（$reason）'}';
      }
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
      onAudioChunk: _onAudioChunk,
    );

    // 把 VAD 后端结论暴露给 UI（首页 / 控制台可展示当前用的是 Silero 还是能量）
    _vadBackendNote = _audioCapture.vadBackendNote;
    log(
      '[TranslationService] VAD 后端=${_audioCapture.vadBackend} '
      'model=$vadModelPath note=$_vadBackendNote',
      name: 'TranslationService',
    );

    if (asrOk && mtOk) {
      _updateStatus('引擎就绪（真实引擎）');
      _lastError = null;
    } else if (!modelsReady) {
      // 没模型：不是「失败」，是「还没准备好」。文案要能指导用户下一步，
      // 而不是甩一句「初始化失败」让他去猜。
      _updateStatus('等待模型');
      _lastError = null;
    } else {
      // 走到这里说明模型齐全但引擎加载失败，engineNote 已在上面被赋成
      // 具体原因（含「原生库缺失 / 加载超时」等），直接透传给用户。
      _lastError = engineNote;
      _updateStatus('初始化失败');
    }

    // 监听引擎变更
    _engineManager.addListener(_onEngineChanged);

    // 恢复悬浮窗显示设置（字号 / 透明度 / 位置）
    //
    // 必须在 `_overlay.warmUp()` 之前：show() 要用 position 决定 gravity。
    // 读取失败会静默退回默认值，不阻塞初始化。
    await OverlaySettingsStore.instance.load();

    // 订阅悬浮窗反向控制通道
    _subscribeOverlayCommands();

    // 预热悬浮窗引擎
    //
    // 冷启动 overlayMain 大约要 5s（插件文档也提到这一点），
    // 如果等用户点「开始」才创建，会出现「点了开始、几秒后字幕条才冒出来」
    // 的体感延迟。这里在 App 初始化阶段就建好引擎（此时用户还在首页），
    // 点开始时是热的。失败不影响功能，warmUp() 内部已吞掉异常。
    unawaited(_overlay.warmUp());
  }

  /// 订阅「overlay → 主 App」的控制命令
  ///
  /// 通道说明：`FlutterScreenOverlay.overlayListener` 与 `shareData()`
  /// 共用插件那一条 `BasicMessageChannel`，但方向相反 ——
  /// 这里收到的是**悬浮窗进程**发出来的消息。
  ///
  /// 注意 `overlayListener` 的 getter 内部会 `setMessageHandler`，
  /// **每取一次就覆盖一次**。所以只能在这里订阅一次并保存
  /// `StreamSubscription`；不要在多处调 `overlayListener`。
  void _subscribeOverlayCommands() {
    _overlayCommandSub?.cancel();
    try {
      _overlayCommandSub =
          FlutterScreenOverlay.overlayListener.listen((dynamic data) {
        if (data is! Map) return;
        final command = readCommand(data);
        if (command == null) {
          log('[Overlay] 收到未知消息: $data', name: 'TranslationService');
          return;
        }
        unawaited(_handleOverlayCommand(command));
      });
    } catch (e) {
      // 测试环境 / 平台通道不可用：降级为「无反向控制」，不影响翻译主链路
      log('[Overlay] 订阅控制通道失败: $e', name: 'TranslationService');
    }
  }

  /// 处理来自悬浮窗的用户操作
  ///
  /// 每个分支都遵循同一个原则：**先改权威状态，再广播回去**。
  /// 只改本地不广播的话，悬浮窗上显示的会是旧值（它自己先改了本地快照，
  /// 但我们这边如果算出不同的结果——比如已经到上限——它就会一直显示错的）。
  Future<void> _handleOverlayCommand(OverlayCommand command) async {
    log('[Overlay] 收到命令: ${command.wire}', name: 'TranslationService');

    switch (command) {
      case OverlayCommand.requestSync:
        // 悬浮窗刚起来（或被重建），把完整状态推过去
        _overlayDismissedByUser = false;
        await _pushOverlaySettings();
        await _pushOverlayState();
        // 窗口刚重建时字幕是空的，把最后一句话补回去，
        // 否则用户切了个位置就看不到刚才的译文了。
        _resendLastSubtitle();

      case OverlayCommand.fontIncrease:
        await _updateOverlaySettings(
          OverlaySettingsStore.instance.current.withLargerFont,
        );

      case OverlayCommand.fontDecrease:
        await _updateOverlaySettings(
          OverlaySettingsStore.instance.current.withSmallerFont,
        );

      case OverlayCommand.cycleOpacity:
        await _updateOverlaySettings(
          OverlaySettingsStore.instance.current.withNextOpacity,
        );

      case OverlayCommand.cyclePosition:
        await _cycleOverlayPosition();

      case OverlayCommand.toggleOrder:
        // 切换「原文在上 / 译文在上」。overlay 已经先本地生效了，
        // 这里负责持久化并广播正确值回去。
        final current = OverlaySettingsStore.instance.current;
        final next = current.order == SubtitleOrder.sourceFirst
            ? SubtitleOrder.targetFirst
            : SubtitleOrder.sourceFirst;
        await _updateOverlaySettings(current.copyWith(order: next));

      case OverlayCommand.hideOverlay:
        // 用户主动收起：只关窗口，服务继续跑
        _overlayDismissedByUser = true;
        await _overlay.hide();
        _clearOverlayIssue();
        notifyListeners();

      case OverlayCommand.stopService:
        // 完全停止：窗口在 stopService 内部先关，避免闪一条空字幕
        _overlayDismissedByUser = false;
        await stopService();
    }
  }

  /// 保存设置并广播给悬浮窗
  ///
  /// 供 UI（主界面设置区）调用。悬浮窗自己调的是内部命令路径，
  /// 但最终都会走到这里，保证「只有一个地方写设置」。
  Future<void> updateOverlaySettings(OverlaySettings next) =>
      _updateOverlaySettings(next);

  /// 循环切换悬浮窗位置（供 UI 调用）
  Future<void> cycleOverlayPosition() => _cycleOverlayPosition();

  /// 保存设置并广播给悬浮窗
  Future<void> _updateOverlaySettings(OverlaySettings next) async {
    final store = OverlaySettingsStore.instance;
    if (next == store.current) {
      // 值没变（比如字号已到上限）：仍要广播一次。
      // 悬浮窗是「先本地改再发命令」，它可能已经乐观地把字改大了，
      // 不回一条正确值，界面就会停在一个不存在的字号上。
      await _pushOverlaySettings();
      return;
    }
    await store.save(next);
    await _pushOverlaySettings();
    notifyListeners();
  }

  /// 循环切换悬浮窗位置
  ///
  /// 位置只能靠关窗重开生效（gravity 不可原地改），
  /// 而重开后 overlay 会发 `requestSync` 回来，所以这里不用额外推状态。
  Future<void> _cycleOverlayPosition() async {
    if (!_isServiceRunning || _overlayDismissedByUser) {
      // 窗口没显示时也允许改设置，留着下次显示用
      final next = OverlaySettingsStore.instance.current.withNextPosition;
      await OverlaySettingsStore.instance.save(next);
      notifyListeners();
      return;
    }

    final next = OverlaySettingsStore.instance.current.withNextPosition;
    await OverlaySettingsStore.instance.save(next);

    final result = await _overlay.reposition(next.position);
    _applyOverlayResult(result);
    if (!result.ok) {
      log(
        '[TranslationService] 切换位置后悬浮窗未能显示: ${result.reason}',
        name: 'TranslationService',
      );
    }
    notifyListeners();
  }

  /// 把当前设置推给悬浮窗
  Future<void> _pushOverlaySettings() async {
    try {
      await FlutterScreenOverlay.shareData({
        'type': OverlayMessageType.settings,
        ...OverlaySettingsStore.instance.current.toMap(),
      });
    } catch (e) {
      log('[Overlay] 推送设置失败: $e', name: 'TranslationService');
    }
  }

  /// 把服务运行状态推给悬浮窗
  Future<void> _pushOverlayState() async {
    try {
      await FlutterScreenOverlay.shareData({
        'type': OverlayMessageType.state,
        'serviceRunning': _isServiceRunning,
      });
    } catch (e) {
      log('[Overlay] 推送状态失败: $e', name: 'TranslationService');
    }
  }

  /// 把最后一句话重新推给刚重建的悬浮窗
  ///
  /// 窗口重建后 overlay widget 是全新的，字幕已经清空。
  /// 不补这一下，用户点「切换位置」就会看到字幕消失。
  void _resendLastSubtitle() {
    if (_subtitleBuffer.isEmpty) return;
    final last = _subtitleBuffer.first;
    _pendingSourceText = last.sourceText;
    _pendingTranslatedText = last.translatedText;
    _pendingIsFinal = last.isFinal;
    _sendToOverlay();
  }

  /// 音频块回调（来自音频捕获服务）
  ///
  /// v0.8.0：收到的是**连续原始 PCM**（不再等 VAD 切段），
  /// 直接转给 ASR 的流式识别器。切句完全交给识别器自带的端点检测。
  void _onAudioChunk(Uint8List audioData) {
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
      // 新一轮服务：清空流式翻译的全部状态。
      // 不清的话，上一轮的译文链会作为 previousTranslation 传给模型，
      // 导致新一句话被"嫁接"到旧字幕上。
      _resetStreamingState();
      // 把「用户主动收起」的意图清掉，
      // 否则上一轮收起过，这一轮点了开始却看不到悬浮窗。
      _overlayDismissedByUser = false;

      // 显示悬浮字幕窗口
      //
      // 顺序很重要：必须放在「音频真的开始流」之后。
      // 否则用户点了开始、但屏幕录制授权被拒（start() 已抛异常走到 catch），
      // 悬浮窗却已经挂出来了 —— 屏幕上留一条永远「等待语音输入...」的黑条。
      await _syncOverlayWithServiceState();

      _updateStatus('服务运行中...');
      // 服务真正跑起来后才开始体检：start 之前引擎还没 start，
      // 立刻检查必然「未响应」，会白白消耗一次失败配额。
      startHealthCheck();
      notifyListeners();
    } catch (e, stack) {
      _lastError = '启动失败: $e';
      _updateStatus('启动失败');
      log('TranslationService start error: $e\n$stack', name: 'TranslationService');
      // 启动失败时确保不会遗留一个假运行的悬浮窗
      await _overlay.hide();
      _clearOverlayIssue();
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
      _clearOverlayIssue();
      return;
    }

    // 用户主动收起了悬浮窗：尊重这个意图，不要把窗口硬拉出来。
    // 否则「收起」按钮等于无效 —— 只要任何一次同步就会重新弹出。
    if (_overlayDismissedByUser) {
      return;
    }

    final result = await _overlay.show();
    _applyOverlayResult(result);
    if (!result.ok) {
      // 把 code 一并打出来：真机复测时靠它区分「权限没给」/
      // 「前台服务被后台启动限制挡住」/「服务起来了但 View 没挂上」。
      log(
        '[TranslationService] 悬浮窗未能显示: code=${result.code} '
        'reason=${result.reason}',
        name: 'TranslationService',
      );
    } else {
      // 窗口刚开：overlay 那边是全新的（甚至连引擎都是刚热的），
      // 不会自己知道当前服务状态和设置，主动推一遍。
      await _pushOverlaySettings();
      await _pushOverlayState();
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
        code: 'NOT_RUNNING',
        reason: '翻译服务未运行，悬浮窗无需显示',
      );
    }
    // 手动重试是用户的明确意图：即使之前点过「收起」，也应当重新显示。
    _overlayDismissedByUser = false;
    final result = await _overlay.show();
    _applyOverlayResult(result);
    if (result.ok) {
      await _pushOverlaySettings();
      await _pushOverlayState();
      _resendLastSubtitle();
    }
    notifyListeners();
    return result;
  }
  
  /// 停止翻译服务
  Future<void> stopService() async {
    if (!_isServiceRunning) return;
    
    _updateStatus('正在停止服务...');
    
    // 先停体检：stop 过程中引擎会一个个置空，
    // 体检会把这些中间态判成「挂了」并触发一次多余的重载。
    stopHealthCheck();
    
    try {
      // 先关悬浮窗：停止过程中引擎会清空字幕，
      // 若窗口还挂着会闪一下空的「等待语音输入...」再消失。
      await _overlay.hide();
      _clearOverlayIssue();
      // 服务停了，「收起」这个意图就不再有意义，清掉，
      // 免得上一条收起状态残留到下一轮启动。
      _overlayDismissedByUser = false;

      await _engineManager.stopASR();
      
      // 停止音频捕获
      await _audioCapture.stop();
      
      _isServiceRunning = false;
      // 停止时也要清掉流式状态：本轮已定稿的句子不该出现在下一轮的
      // previousTranslation / 前文上下文里。
      _resetStreamingState();
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
  
  /// ASR 结果回调 —— **实时字幕的核心链路**
  ///
  /// ## v0.8.0：中间结果也翻译
  ///
  /// 旧实现只在 `isFinal` 时翻译，等于「等整句说完再翻」：
  /// 用户说 5 秒，前 5 秒屏幕全空。这不是实时翻译。
  ///
  /// 现在每次 ASR 文本变化都触发一次翻译，并把「本句上一版译文」
  /// 一起交给模型 —— 这正是 StreamRevise 系列被设计出来的用法：
  ///
  /// | 时刻 | ASR 文本 | 传给模型的 previousTranslation | 模型行为 |
  /// |---|---|---|---|
  /// | t0 | "I want to" | ""（首译） | 译出半句，不猜后文 |
  /// | t1 | "I want to go" | "我想" | 保留"我想"，只补新内容 |
  /// | t2 | "I want to go home" | "我想去" | 保留"我想去"，补"回家" |
  /// | t3（定稿） | 同上 | "我想去回家" | 补齐结尾标点，收尾 |
  ///
  /// ## 并发控制
  ///
  /// 模型一次只能跑一个生成。ASR 每 ~300ms 就可能更新一次，
  /// 如果不加控制会堆积请求、越翻越慢（这正是「字幕卡住不动」的成因）。
  ///
  /// 策略：**最新优先**。新文本到来时取消正在跑的那次推理，
  /// 立刻用最新文本重开一次。丢弃的中间态没有价值 ——
  /// 反正下一次会用更完整的文本重译。
  void _onASRResult(ASRResult result) {
    final text = result.text.trim();
    if (text.isEmpty) return;

    log(
      '[TranslationService] ASR: "$text" (final: ${result.isFinal})',
      name: 'TranslationService',
    );

    // 已定稿的句子不再接受新内容（同一句的迟到中间结果直接忽略）
    if (_sentenceFinalized && !result.isFinal) {
      return;
    }

    _currentPartialText = text;
    _sentenceSource = text;

    unawaited(_translateCurrentSentence(isFinal: result.isFinal));
  }

  /// 翻译「当前句」的最新版本
  ///
  /// [isFinal] 为 true 表示 ASR 已定稿，本轮翻译完成后要把这句
  /// 归入「前文上下文」并开启新句。
  Future<void> _translateCurrentSentence({required bool isFinal}) async {
    // ## 本次翻译的「代号」
    //
    // 必须**同步**自增（在任何 await 之前）：ASR 每 ~300ms 就可能来一次新结果，
    // 两次调用会在 `await mt.cancel()` 处交错。如果等 cancel 之后才取号，
    // 后发起的那次可能拿到更小的号 —— 于是它的 chunk 会被误判成过期结果，
    // 把最新的译文盖掉。
    //
    // 有了它，`onChunk` 才能判断「这个 chunk 属于已被取代的那次推理」
    // 并直接丢弃，避免旧 token 打到屏幕上造成字幕倒退。
    final runId = ++_mtRunId;

    final text = _sentenceSource;
    if (text.isEmpty) return;
    final mt = _engineManager.currentMT;
    if (mt == null) {
      _isTranslating = false;
      return;
    }

    // 取消上一次未完成的推理（最新优先）
    if (mt is LlamaMTEngine) {
      await mt.cancel();
    }

    _isTranslating = true;
    final previous = _sentenceTranslation;
    final previousSource = _sentencePreviousSource;

    // 构造请求时**必须**带上上一版译文与前文上下文。
    // 少传任何一个，StreamRevise 模型就退回成普通翻译模型，
    // 「前缀保留 / 增量修订」能力全部失效。
    //
    // previousSource 单独传：Hy-MT2 的模板有独立的
    // `Previous version of the current source:` 槽位，必须先记下
    // 「本轮识别文本」，下一轮才有真正的上一版原文可用。
    final request = StreamTranslateRequest(
      text: text,
      previousTranslation: previous,
      previousSource: previousSource,
      recentSources: List<String>.from(_recentSources),
      isFinal: isFinal,
    );

    // 本轮结束后，本次文本就是「下一轮的上一版原文」。
    //
    // 必须在发起翻译**之前**记：翻译是异步的，中间可能又有新 ASR 结果进来并
    // 覆盖 `_sentenceSource`；用局部变量 `text` 才对应本次请求的那一版。
    if (!isFinal) {
      _sentencePreviousSource = text;
    }

    try {
      // 只有真实引擎才走修订接口；其它实现（测试用 Mock）走通用接口。
      final completer = Completer<MTResult?>();
      if (mt is LlamaMTEngine) {
        unawaited(
          mt.translateStreamRevise(
            request: request,
            onChunk: (chunk) =>
                _onMTChunk(runId: runId, chunk: chunk, sourceText: text),
            onComplete: (result) {
              if (!completer.isCompleted) completer.complete(result);
            },
            onError: (error, stack) {
              if (!completer.isCompleted) completer.completeError(error, stack);
            },
          ),
        );
      } else {
        unawaited(
          mt.translateStream(
            text: text,
            onChunk: (chunk) =>
                _onMTChunk(runId: runId, chunk: chunk, sourceText: text),
            onComplete: (result) {
              if (!completer.isCompleted) completer.complete(result);
            },
            onError: (error, stack) {
              if (!completer.isCompleted) completer.completeError(error, stack);
            },
          ),
        );
      }

      final result = await completer.future;
      if (result == null) {
        if (runId == _mtRunId) _isTranslating = false;
        return;
      }

      var translated = result.translatedText.trim();

      // 模型对极短片段可能返回空串（模型卡明确说明这是预期行为）。
      // 此时保留上一版译文继续显示，不要清空 —— 清空会让字幕闪烁。
      if (translated.isEmpty) {
        translated = previous;
      }
      if (translated.isEmpty) {
        if (runId == _mtRunId) _isTranslating = false;
        return;
      }

      // ## 先确认这次结果还「有效」
      //
      // 上面的 await 可能已经等了很久，期间新的 ASR 结果完全可能再来一次。
      // Llama 引擎靠 cancel 抛 TranslationCancelledException 兜住，
      // 但只要换了引擎实现（Mock / 未来新引擎）就可能没有这层保护 ——
      // 那样旧结果会直接把用户刚看到的更新译文盖回去。
      //
      // 所以出口处必须自己判一次代号，不能依赖引擎的取消语义。
      if (runId != _mtRunId) return;

      // 更新译文链：下一轮请求要带这一版作为 previousTranslation
      _sentenceTranslation = translated;
      _currentTranslatedPartial = translated;

      // 推给悬浮窗与 UI（内部有 100ms 防抖）
      _scheduleDebouncedUpdate(
        sourceText: text,
        translatedText: translated,
        isFinal: isFinal,
      );

      if (isFinal) {
        _commitSentence(text, translated);
      }
    } catch (e, stack) {
      // 「被更新的识别结果打断」是实时字幕的**正常节奏**，不是错误。
      //
      // 不加这个分支的话，用户每说一句话都会看到几十条「MT Error」日志
      // （ASR 每 ~300ms 更新一次 → 每句话都可能取消若干次）。
      if (e is TranslationCancelledException) {
        return;
      }
      // 过期那次推理的错误与用户无关（它本来就已经被丢弃），
      // 报出来只会让状态栏闪一条莫名其妙的红字。
      if (runId != _mtRunId) return;
      _lastError = '翻译错误: $e';
      log(
        '[TranslationService] MT Error: $e\n$stack',
        name: 'TranslationService',
      );
      notifyListeners();
    } finally {
      // 只有「还是最新那次」才能清标志位。
      //
      // 旧推理被新识别结果取代后也会走到 finally，如果无脑清零，
      // 会把新推理刚设上的 `_isTranslating = true` 抹掉，
      // 界面的「翻译中」转圈就提前熄火了。
      if (runId == _mtRunId) _isTranslating = false;
    }
  }

  /// 接收 MT 的流式 token（`onChunk`）
  ///
  /// ## 为什么必须在 token 级接上屏
  ///
  /// 以前这里是空实现 `(_) {}`，译文只在**整次生成结束后**才推给界面。
  /// 一次生成要 prefill + 逐 token decode，1.8B 模型在手机上动辄一两秒，
  /// 用户看到的就是「一直转圈、字幕半天不出来」。
  ///
  /// 接上之后，观感变成「第一个字立刻出现，然后越写越多」，最后整句定稿时
  /// 再用完整结果覆盖 —— 这正是用户要求的「边识别边部分翻译，
  /// 整句结束再出完整译文」。
  ///
  /// ## 三个必须做的过滤
  ///
  /// 1. **过期推理丢弃**：`runId != _mtRunId` 说明这次推理已经被更新的
  ///    ASR 结果取代。它迟到的 token 会把新译文盖回旧内容，字幕来回跳。
  /// 2. **重复内容丢弃**：StreamRevise 会大段沿用上一版译文，相邻 chunk
  ///    常常完全相同。不比对就白刷一遍 UI 与悬浮窗消息。
  /// 3. **空串丢弃**：模型对极短片段会返回空串（模型卡的已知行为）。
  void _onMTChunk({
    required int runId,
    required MTChunk chunk,
    required String sourceText,
  }) {
    if (runId != _mtRunId) return;
    final partial = chunk.text.trim();
    if (partial.isEmpty) return;
    if (partial == _lastStreamedPartial) return;
    _lastStreamedPartial = partial;
    _currentTranslatedPartial = partial;
    // 走同一条节流链路：悬浮窗与主界面拿到的东西必须与最终结果同源，
    // 否则会出现「中间态显示了、定稿时却跳一下」的错位。
    _scheduleDebouncedUpdate(
      sourceText: sourceText,
      translatedText: partial,
      isFinal: false,
    );
  }

  /// 定稿一句：归入前文上下文 + 清空本句状态
  void _commitSentence(String source, String translation) {
    _sentenceFinalized = true;

    // 前文上下文只保留最近 N 句原文（模型卡建议最多 5 句）
    if (source.trim().isNotEmpty) {
      _recentSources.add(source.trim());
      while (_recentSources.length > maxContextSentences) {
        _recentSources.removeAt(0);
      }
    }

    _addSubtitleEntry(
      sourceText: source,
      translatedText: translation,
      isFinal: true,
    );

    // 开启新句：清空本句状态，但**保留** _recentSources 作为上下文
    _sentenceSource = '';
    _sentencePreviousSource = '';
    _sentenceTranslation = '';
    _sentenceFinalized = false;
    _currentPartialText = '';
    _currentTranslatedPartial = '';
    // 清去重基准：下一句的第一版部分译文即使与这句的最终译文相同，
    // 也必须能显示出来，否则新句开头会「先空一段」。
    _lastStreamedPartial = '';
  }

  /// 前文上下文（供引擎读取，测试也用它做断言）
  List<String> get recentSources => List.unmodifiable(_recentSources);

  /// 当前句的上一版译文（供测试断言「前缀保留」链路是否生效）
  String get currentSentenceTranslation => _sentenceTranslation;

  /// 清空全部流式翻译状态（服务启动 / 停止时调用）
  ///
  /// 必须清的三处：
  /// - `_sentenceSource` / `_sentenceTranslation`：本句进行中的状态；
  /// - `_recentSources`：前文上下文，跨轮复用会让新对话被旧话题带偏；
  /// - `_sentenceFinalized`：上一轮如果最后一个字定稿后立刻停止，
  ///   这个标志会残留成 true，导致新一轮第一句的中间结果全被忽略。
  void _resetStreamingState() {
    _sentenceSource = '';
    _sentencePreviousSource = '';
    _sentenceTranslation = '';
    _recentSources.clear();
    _sentenceFinalized = false;
    _currentPartialText = '';
    _currentTranslatedPartial = '';
    _isTranslating = false;
    // 让仍在飞的那次推理彻底作废：它的 token 已经不该上屏。
    // 不清的话，停止服务后残余 token 还会往缓冲区里补一条字幕。
    _mtRunId += 1;
    _lastStreamedPartial = '';
    _pendingSourceText = '';
    _pendingTranslatedText = '';
    _pendingIsFinal = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  /// ASR 错误回调
  void _onASRError(Object error, StackTrace stack) {
    _lastError = 'ASR 错误: $error';
    _updateStatus('ASR 出错');
    log('[TranslationService] ASR Error: $error\n$stack', name: 'TranslationService');
    notifyListeners();
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
    
    // ## 为什么要区分「插入」与「原地更新」
    //
    // v0.8.0 之前这里只会 `insert(0, entry)`。字幕只在**整句定稿**时才写一次，
    // 所以「一句一条」勉强成立。一旦把 MT 的 token 流接上来（每几十毫秒一次），
    // 同一条字幕会变成几十条历史记录，缓冲区瞬间被一句话塞满，
    // 用户看到的「字幕历史」全是同一句在滚雪球。
    //
    // 现在按顶部条目的状态分流：
    // - 顶部条目还在进行中（`isFinal == false`）→ 原地替换；
    // - 顶部条目已定稿，但本次原文与它相同 → 原地替换（把它升级为定稿）；
    // - 否则 → 这是下一句，插入新条目。
    //
    // 第二条不是多余的：定稿时链路会写两次（一次走
    // `_scheduleDebouncedUpdate(isFinal: true)`，一次走 `_commitSentence()`），
    // 内容相同。不合并就会插入两条一模一样的字幕 ——
    // 这正是用户反复报的「同一句重复」。
    final top = _subtitleBuffer.isEmpty ? null : _subtitleBuffer.first;
    final replaceTop =
        top != null && (!top.isFinal || top.sourceText == sourceText);

    if (replaceTop) {
      // 保留原始时间戳：字幕的「出现时刻」应该是这句第一次露头的时间，
      // 而不是最后一次 token 刷新的时间，否则历史里每一行都像刚刚才说。
      _subtitleBuffer[0] = SubtitleEntry(
        sourceText: sourceText,
        translatedText: translatedText,
        timestamp: top.timestamp,
        isFinal: isFinal,
        sourceLang: _mtSourceLang,
        targetLang: _mtTargetLang,
      );
      notifyListeners();
      return;
    }

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
        // 必须带 type：主 → overlay 方向上除了字幕，还有 settings / state，
        // 不带类型的话 overlay 只能靠「有没有 sourceText 字段」猜，很脆。
        'type': OverlayMessageType.subtitle,
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
  ///
  /// v0.6.0 起会持久化：App 重启后仍是上次选的语言。
  /// 落盘失败不影响本次运行（`saveLanguages` 内部已吞异常）。
  Future<void> setASRLanguage(String language) async {
    _asrLanguage = language;
    await AppSettingsStore.instance.saveLanguages(asrLanguage: language);
    await _engineManager.switchASRLanguage(language);
    notifyListeners();
  }

  /// 切换 MT 语言对
  ///
  /// v0.6.0 起会持久化：App 重启后仍是上次选的语向。
  Future<void> setMTLanguagePair(String sourceLang, String targetLang) async {
    _mtSourceLang = sourceLang;
    _mtTargetLang = targetLang;
    await AppSettingsStore.instance.saveLanguages(
      mtSourceLang: sourceLang,
      mtTargetLang: targetLang,
    );
    await _engineManager.switchMTLanguagePair(sourceLang, targetLang);
    notifyListeners();
  }

  /// 切换翻译模型（决定提示词模板 / 内存需求）
  ///
  /// 只记录选择并落盘，真正的重新加载由调用方决定
  /// （下载页在下载完成后调 [reloadEngines]）。
  Future<void> setMtModelVariant(MtModelVariant variant) async {
    if (_mtModelVariant == variant) return;
    _mtModelVariant = variant;
    await AppSettingsStore.instance.saveModelChoice(mtVariant: variant);
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
  
  // ---------------------------------------------------------------------------
  // 仅测试钩子（`@visibleForTesting` 在这里不适用：需要从 test 目录直接调）
  //
  // 为什么需要它们：这条链路的真实入口是 ASR 回调，它依赖 sherpa 原生库；
  // 而 chunk 分发口 `_onMTChunk` / 字幕写入口 `_addSubtitleEntry` 是私有的。
  // 不想为了可测性把私有成员改成公有（那会让「谁能写字幕」失去约束），
  // 所以开三个显式、带 debug 前缀的入口。
  //
  // 名字一律以 debug 开头：一看就知道不该在业务代码里调。
  // ---------------------------------------------------------------------------

  /// 当前推理代号（用于测试构造「过期 run」）
  int get debugCurrentRunId => _mtRunId;

  /// 直接喂一个 MT chunk，走与真实链路完全相同的分发口
  void debugFeedChunk({
    required int runId,
    required String text,
    required String sourceText,
  }) {
    _onMTChunk(
      runId: runId,
      chunk: MTChunk(text: text, isFinal: false, chunkIndex: 0),
      sourceText: sourceText,
    );
  }

  /// 直接写一条字幕，走与真实链路完全相同的合并 / 定稿逻辑
  void debugSeedSubtitle({
    required String sourceText,
    required String translatedText,
    required bool isFinal,
  }) {
    _addSubtitleEntry(
      sourceText: sourceText,
      translatedText: translatedText,
      isFinal: isFinal,
    );
  }

  /// 清空字幕缓冲区
  void clearSubtitles() {
    _subtitleBuffer.clear();
    notifyListeners();
  }
  
  @override
  void dispose() {
    _debounceTimer?.cancel();
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _overlayCommandSub?.cancel();
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