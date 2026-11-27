/// 语言与引擎选择的持久化
///
/// ## 为什么需要单独一个 Store
///
/// `OverlaySettingsStore` 只管悬浮窗的显示（字号/透明度/位置），
/// 而「源语言 / 目标语言 / 识别语种 / 翻译模型」是**业务语义**设置，
/// 生命周期和用途都不一样：
///
/// - 悬浮窗设置：窗口重建时要回读（`requestSync`），读得极频繁；
/// - 语言设置：只在 App 冷启动时读一次，之后由用户操作驱动。
///
/// 硬塞进同一个类会让两边的 `load()` 互相牵连 —— 比如悬浮窗那边
/// 失败重试时会把语言设置也一起重置。
///
/// ## 默认值策略
///
/// 首次启动（没有任何持久化）时的默认值必须**可用**：
/// - `en -> zh`：英语听中文，是「实时字幕」最常见的用法；
/// - 识别语种 = `zhEn`：中英双语模型覆盖面最广，且体积适中。
///
/// 不能默认成 `ja`：本项目没有任何日语专用识别模型，
/// 默认成日语会让新用户第一次打开就看到「模型缺失」。
library live_translate.core.service.app_settings;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:live_translate/core/model/model_catalog.dart';

/// 语言与引擎选择的持久化（单例，带内存缓存）
class AppSettingsStore {
  AppSettingsStore._();

  static final AppSettingsStore instance = AppSettingsStore._();

  // ---- 持久化键 ----
  //
  // 统一加 `app.` 前缀，避免和 overlay.* / models.* 混在一起看不出归属。
  static const String _kAsrLanguage = 'app.asr_language';
  static const String _kMtSourceLang = 'app.mt_source_lang';
  static const String _kMtTargetLang = 'app.mt_target_lang';
  static const String _kAsrVariant = 'app.asr_variant';
  static const String _kMtVariant = 'app.mt_variant';
  static const String _kWithVad = 'app.with_vad';

  // ---- 默认值 ----
  static const String defaultAsrLanguage = 'en';
  static const String defaultMtSourceLang = 'en';
  static const String defaultMtTargetLang = 'zh';
  static const AsrModelVariant defaultAsrVariant = AsrModelVariant.zhEn;
  static const MtModelVariant defaultMtVariant = MtModelVariant.hyMt15Q4;
  static const bool defaultWithVad = true;

  // ---- 内存缓存 ----
  String _asrLanguage = defaultAsrLanguage;
  String _mtSourceLang = defaultMtSourceLang;
  String _mtTargetLang = defaultMtTargetLang;
  AsrModelVariant _asrVariant = defaultAsrVariant;
  MtModelVariant _mtVariant = defaultMtVariant;
  bool _withVad = defaultWithVad;
  bool _loaded = false;

  String get asrLanguage => _asrLanguage;
  String get mtSourceLang => _mtSourceLang;
  String get mtTargetLang => _mtTargetLang;
  AsrModelVariant get asrVariant => _asrVariant;
  MtModelVariant get mtVariant => _mtVariant;
  bool get withVad => _withVad;

  /// 是否已从持久化恢复
  bool get isLoaded => _loaded;

  /// 从持久化恢复（幂等）
  ///
  /// 读取失败（测试环境 / 插件不可用）时静默保留默认值，
  /// 与 `OverlaySettingsStore.load` 保持一致。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _asrLanguage = _nonEmpty(prefs.getString(_kAsrLanguage), defaultAsrLanguage);
      _mtSourceLang =
          _nonEmpty(prefs.getString(_kMtSourceLang), defaultMtSourceLang);
      _mtTargetLang =
          _nonEmpty(prefs.getString(_kMtTargetLang), defaultMtTargetLang);
      _asrVariant = _asrVariantFromWire(prefs.getString(_kAsrVariant));
      _mtVariant = _mtVariantFromWire(prefs.getString(_kMtVariant));
      _withVad = prefs.getBool(_kWithVad) ?? defaultWithVad;
      _loaded = true;
    } catch (_) {
      // 保持默认值，但**不**置 _loaded，下次还能再试一次
    }
  }

  /// 保存语言对
  ///
  /// 先更新内存再落盘：即使用户立刻关掉 App，本次运行的界面也已经对了。
  Future<void> saveLanguages({
    String? asrLanguage,
    String? mtSourceLang,
    String? mtTargetLang,
  }) async {
    if (asrLanguage != null && asrLanguage.trim().isNotEmpty) {
      _asrLanguage = asrLanguage.trim();
    }
    if (mtSourceLang != null && mtSourceLang.trim().isNotEmpty) {
      _mtSourceLang = mtSourceLang.trim();
    }
    if (mtTargetLang != null && mtTargetLang.trim().isNotEmpty) {
      _mtTargetLang = mtTargetLang.trim();
    }
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAsrLanguage, _asrLanguage);
      await prefs.setString(_kMtSourceLang, _mtSourceLang);
      await prefs.setString(_kMtTargetLang, _mtTargetLang);
    } catch (_) {
      // 落盘失败只影响下次启动，本次运行不受影响
    }
  }

  /// 保存「下载哪种识别模型 / 翻译模型 / 要不要 VAD」
  Future<void> saveModelChoice({
    AsrModelVariant? asrVariant,
    MtModelVariant? mtVariant,
    bool? withVad,
  }) async {
    if (asrVariant != null) _asrVariant = asrVariant;
    if (mtVariant != null) _mtVariant = mtVariant;
    if (withVad != null) _withVad = withVad;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAsrVariant, _asrVariant.name);
      await prefs.setString(_kMtVariant, _mtVariant.name);
      await prefs.setBool(_kWithVad, _withVad);
    } catch (_) {
      // 同上
    }
  }

  /// 仅用于测试：重置缓存
  void debugReset() {
    _asrLanguage = defaultAsrLanguage;
    _mtSourceLang = defaultMtSourceLang;
    _mtTargetLang = defaultMtTargetLang;
    _asrVariant = defaultAsrVariant;
    _mtVariant = defaultMtVariant;
    _withVad = defaultWithVad;
    _loaded = false;
  }

  // ---- 解析辅助 ----

  static String _nonEmpty(String? raw, String fallback) {
    final value = raw?.trim();
    return (value == null || value.isEmpty) ? fallback : value;
  }

  /// 未知 / 已删除的枚举值必须退回默认，不能抛异常
  ///
  /// `Enum.byName` 在值不存在时会抛 `ArgumentError`。持久化数据是
  /// 「上一次运行的代码写的」，用户升级 App 后完全可能读到已经删掉的
  /// 枚举名 —— 那种情况下必须能用，不能白屏。
  static AsrModelVariant _asrVariantFromWire(String? wire) {
    for (final v in AsrModelVariant.values) {
      if (v.name == wire) return v;
    }
    return defaultAsrVariant;
  }

  static MtModelVariant _mtVariantFromWire(String? wire) {
    for (final v in MtModelVariant.values) {
      if (v.name == wire) return v;
    }
    return defaultMtVariant;
  }
}
