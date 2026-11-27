/// 语言注册表 —— 全项目「支持哪些语言」的唯一事实来源
///
/// ## 为什么需要它（v0.7.0）
///
/// v0.6.0 把识别模型从 3 种扩到了 9 种，但「语言」这个概念在代码里
/// 散落了至少 6 处彼此不一致的定义：
///
/// | 位置 | 内容 | 问题 |
/// |---|---|---|
/// | `main_screen.dart` 三个下拉框 | `en/ja/zh/ko` | 只有 4 种，其余 5 种模型下了也选不到 |
/// | `SherpaASREngine.supportedLanguages` | `en/zh/ja/ko/ru/th/vi/ar/id` | 缺 `fr/de/es`，`switchLanguage` 会抛异常 |
/// | `ModelCatalog.recommendedFor` | 12 种 | 比上面两个都全 |
/// | `LlamaMTEngine._languageNames` | 9 种 | 缺 `fr/de/es`，prompt 会写出语言代码 |
/// | `LlamaMTEngine.supportedLanguagePairs` | 11 个固定方向 | `en→ru` 之类直接抛 `ArgumentError` |
/// | `MockASR/MockMT` | 4 种 | 与真实引擎不一致 |
///
/// 后果是真实崩溃（不是理论问题）：
/// - 用户下载了**法语**识别模型 → 界面上**根本选不到法语** → 模型白下；
/// - 即使能选，`SherpaASREngine.switchLanguage('fr')` 会抛 `ArgumentError`，
///   而调用方 `setASRLanguage` 没有 try/catch → **未捕获异步异常**；
/// - 选 `en→ru` 翻译 → `switchLanguagePair` 抛 `ArgumentError`。
///
/// 现在所有语言都从这里取。新增语种只需要改这一个文件。
///
/// ## 设计约束
///
/// - **本文件不 import 任何模型层 / 存储层**，只依赖 `mt_engine.dart` 里的
///   纯数据类 `LanguagePair`。依赖方向是单向的（语言 ← 引擎 ← 模型），
///   不会形成循环。
/// - `englishName` 是 MT prompt 里写进模型的全称（`Japanese` 而不是 `ja`）。
///   混元 / Qwen 的指令模板都要求自然语言名，写代码会让输出不稳定。
library live_translate.core.i18n.language_registry;

import 'package:live_translate/core/engine/mt_engine.dart' show LanguagePair;

/// 一门语言的元数据
class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.chineseName,
    required this.nativeName,
    required this.englishName,
  });

  /// BCP-47 语言代码（`en` / `zh` / `ja` …）
  ///
  /// 这是持久化、引擎 API、`ModelCatalog.recommendedFor` 共用的键。
  /// **一旦发布就不能改**，否则用户升级后读到的旧值会失效。
  final String code;

  /// 中文名（`英语`）
  final String chineseName;

  /// 母语名（`English` / `日本語` / `한국어`）
  ///
  /// 母语名让用户一眼认得出自己的语言，比拼音或英文名有用得多。
  final String nativeName;

  /// 英文全称（`English` / `Japanese`）
  ///
  /// **专门给 MT prompt 用**，不要拿它做 UI 文案。
  final String englishName;

  /// 下拉框里显示的完整标签，如 `英语 (English)`
  ///
  /// 中文名和母语名相同时（中文 / 简体中文）不做去重：
  /// 保持格式统一，避免「有的条目有括号有的没有」的视觉抖动。
  String get displayLabel => '$chineseName ($nativeName)';

  /// 语言对显示名，如 `English → Japanese`
  String pairLabelTo(AppLanguage target) =>
      '$englishName → ${target.englishName}';

  @override
  String toString() => code;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AppLanguage && code == other.code;

  @override
  int get hashCode => code.hashCode;
}

/// 全项目语言定义的唯一入口
abstract final class LanguageRegistry {
  /// 应用认识的全部语言。
  ///
  /// **顺序即 UI 下拉框顺序**：把最常用的中英日韩排在前面，
  /// 用户八成不用滚动就能选到。新增语种请追加到末尾，不要插队
  /// （插队会让老用户的下拉框位置突然变化）。
  ///
  /// 每一种都满足：
  /// - 有可用的 ASR 识别模型（专用模型或八语种多语模型，见
  ///   `ModelCatalog.recommendedFor`）；
  /// - 有可用的 MT 翻译能力（Hy-MT1.5 / Qwen2.5 都是多语模型）。
  static const List<AppLanguage> all = <AppLanguage>[
    AppLanguage(
      code: 'zh',
      chineseName: '中文',
      nativeName: '简体中文',
      englishName: 'Chinese',
    ),
    AppLanguage(
      code: 'en',
      chineseName: '英语',
      nativeName: 'English',
      englishName: 'English',
    ),
    AppLanguage(
      code: 'ja',
      chineseName: '日语',
      nativeName: '日本語',
      englishName: 'Japanese',
    ),
    AppLanguage(
      code: 'ko',
      chineseName: '韩语',
      nativeName: '한국어',
      englishName: 'Korean',
    ),
    AppLanguage(
      code: 'ru',
      chineseName: '俄语',
      nativeName: 'Русский',
      englishName: 'Russian',
    ),
    AppLanguage(
      code: 'fr',
      chineseName: '法语',
      nativeName: 'Français',
      englishName: 'French',
    ),
    AppLanguage(
      code: 'de',
      chineseName: '德语',
      nativeName: 'Deutsch',
      englishName: 'German',
    ),
    AppLanguage(
      code: 'es',
      chineseName: '西班牙语',
      nativeName: 'Español',
      englishName: 'Spanish',
    ),
    AppLanguage(
      code: 'th',
      chineseName: '泰语',
      nativeName: 'ไทย',
      englishName: 'Thai',
    ),
    AppLanguage(
      code: 'vi',
      chineseName: '越南语',
      nativeName: 'Tiếng Việt',
      englishName: 'Vietnamese',
    ),
    AppLanguage(
      code: 'ar',
      chineseName: '阿拉伯语',
      nativeName: 'العربية',
      englishName: 'Arabic',
    ),
    AppLanguage(
      code: 'id',
      chineseName: '印尼语',
      nativeName: 'Bahasa Indonesia',
      englishName: 'Indonesian',
    ),
  ];

  /// ASR 可选语种代码（`SherpaASREngine.supportedLanguages` 的来源）
  ///
  /// 目前与 [all] 完全一致，但**故意保留独立 getter**：
  /// 将来如果出现「某语种只有翻译模型、没有识别模型」（比如小语种），
  /// 只需要在这里过滤，调用方一行都不用改。
  static List<String> get asrLanguages =>
      all.map((language) => language.code).toList(growable: false);

  /// MT 可选语种代码（源语言 / 目标语言下拉框的来源）
  static List<String> get mtLanguages =>
      all.map((language) => language.code).toList(growable: false);

  /// UI 下拉框条目（ASR 识别语言）
  static List<AppLanguage> get asrOptions => all;

  /// UI 下拉框条目（MT 源 / 目标语言）
  static List<AppLanguage> get mtOptions => all;

  /// 按代码查语言；未知代码返回 null
  ///
  /// 不做 `firstWhere(orElse: throw)`：持久化里可能残留已删除的语种，
  /// 那种情况必须能降级，不能白屏（与 `AppSettingsStore._asrVariantFromWire`
  /// 的处理原则一致）。
  static AppLanguage? byCode(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final language in all) {
      if (language.code == code) return language;
    }
    return null;
  }

  /// 代码是否被本应用认识
  static bool isKnown(String? code) => byCode(code) != null;

  /// 代码 → MT prompt 用的英文全称
  ///
  /// 未知代码原样返回：翻译质量可能下降，但**不会崩**，
  /// 也比抛异常把整条翻译链路打断要好。
  static String mtPromptName(String code) => byCode(code)?.englishName ?? code;

  /// 代码 → 下拉框标签；未知代码显示大写代码
  static String displayLabel(String code) =>
      byCode(code)?.displayLabel ?? code.toUpperCase();

  /// 全部合法翻译方向（源 ≠ 目标，12 种语言共 132 个方向）
  ///
  /// 旧实现在 `LlamaMTEngine` 里硬编码了 11 个方向，导致
  /// `en→ru`、`ja→fr` 这类完全合理的组合会抛 `ArgumentError`。
  /// 翻译模型本身是多语的（指令式，语种只写在 prompt 里），
  /// 不存在「只支持这 11 个方向」的物理限制 —— 那只是没写全。
  ///
  /// 源语言 == 目标语言不生成：那是「中文再翻成中文」，
  /// 模型会原样输出，对用户没有任何价值。
  static final List<LanguagePair> mtPairs =
      List<LanguagePair>.unmodifiable(<LanguagePair>[
        for (final source in all)
          for (final target in all)
            if (source.code != target.code)
              LanguagePair(
                source: source.code,
                target: target.code,
                displayName: source.pairLabelTo(target),
              ),
      ]);
}
