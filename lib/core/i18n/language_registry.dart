/// 语言注册表 —— 全项目「支持哪些语言」的唯一事实来源
///
/// ## v0.8.0：收敛为中日英三语
///
/// 早期版本支持 12 种语言 / 132 个翻译方向，但那是**能力虚胖**：
///
/// - 翻译模型（Hy-MT2 / Hy-MT3 StreamRevise）**只在中文、英语、日语**
///   三种语言上训练过。其余语种属于零样本外推，质量不可控；
/// - 每种语言都要配一套 ASR 四件套（encoder/decoder/joiner/tokens），
///   下载体积翻倍，而用户实际只用中日英；
/// - 语言清单越长，`DropdownButton` 越难用，设置页也越难理解。
///
/// 所以现在**只保留 `zh` / `en` / `ja`**。要加新语种，必须先确认
/// MT 模型真的训练过该语种，否则等于给用户一个翻译不准的假选项。
///
/// ## 设计约束
///
/// - **本文件不 import 任何模型层 / 存储层**，只依赖 `mt_engine.dart` 里的
///   纯数据类 `LanguagePair`。依赖方向是单向的（语言 ← 引擎 ← 模型），
///   不会形成循环。
/// - 两套提示词命名 **必须分开**（这是踩过的坑）：
///   - Hy-MT3 的 StreamRevise 模板要求**中文名**（`中文` / `英语` / `日语`）；
///   - Hy-MT2 的 StreamRevise 模板要求**英文全称**（`Chinese` / `English`）。
///   用混了不会报错，只会输出原文或乱码。
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

  /// BCP-47 语言代码（`en` / `zh` / `ja`）
  ///
  /// 这是持久化、引擎 API、`ModelCatalog.recommendedFor` 共用的键。
  /// **一旦发布就不能改**，否则用户升级后读到的旧值会失效。
  final String code;

  /// 中文名（`英语`）
  ///
  /// 同时用作 **Hy-MT3 StreamRevise 模板里的目标语言名**。
  final String chineseName;

  /// 母语名（`English` / `日本語`）
  ///
  /// 母语名让用户一眼认得出自己的语言，比拼音或英文名有用得多。
  final String nativeName;

  /// 英文全称（`English` / `Japanese`）
  ///
  /// 同时用作 **Hy-MT2 StreamRevise 模板里的语言名**。不要拿它做 UI 文案。
  final String englishName;

  /// 下拉框里显示的完整标签，如 `英语 (English)`
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
  /// 应用认识的全部语言：**仅中文 / 英语 / 日语**。
  ///
  /// 顺序即 UI 下拉框顺序：中文、英语、日语。
  ///
  /// 每一种都满足：
  /// - 有可用的 ASR 识别模型（见 `ModelCatalog.recommendedFor`）；
  /// - 被 StreamRevise 翻译模型训练覆盖。
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
  ];

  /// ASR 可选语种代码（`SherpaASREngine.supportedLanguages` 的来源）
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
  /// 不做 `firstWhere(orElse: throw)`：持久化里可能残留已删除的语种
  /// （比如用户从 v0.7 升级上来，存着 `ko`），那种情况必须能降级，
  /// 不能白屏。
  static AppLanguage? byCode(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final language in all) {
      if (language.code == code) return language;
    }
    return null;
  }

  /// 代码是否被本应用认识
  static bool isKnown(String? code) => byCode(code) != null;

  /// 代码 → **Hy-MT2** StreamRevise 模板用的英文全称
  ///
  /// 未知代码原样返回：翻译质量可能下降，但**不会崩**，
  /// 也比抛异常把整条翻译链路打断要好。
  static String mtPromptName(String code) => byCode(code)?.englishName ?? code;

  /// 代码 → **Hy-MT3** StreamRevise 模板用的中文名
  ///
  /// Hy-MT3 官方模板明确要求中文名称（`翻译为日语`），写英文会掉质量。
  static String mtPromptNameZh(String code) =>
      byCode(code)?.chineseName ?? code;

  /// 代码 → 下拉框标签；未知代码显示大写代码
  static String displayLabel(String code) =>
      byCode(code)?.displayLabel ?? code.toUpperCase();

  /// 全部合法翻译方向（源 ≠ 目标，3 种语言共 6 个方向）
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