/// 语言注册表一致性测试
///
/// ## 为什么这个文件必须存在
///
/// v0.6.0 把识别模型从 3 种扩到 9 种，但「语言」在代码里散落了 6 处
/// 彼此不一致的定义。这不是「代码不好看」，而是**真机上会崩**：
///
/// - 用户下载法语识别模型 → 界面上根本选不到（`main_screen` 只有 4 种）；
/// - 就算能选，`SherpaASREngine.switchLanguage('fr')` 抛 `ArgumentError`，
///   而 `setASRLanguage` 没有 try/catch → 未捕获异步异常；
/// - 选 `en→ru` 翻译 → `switchLanguagePair` 抛 `ArgumentError`。
///
/// 这些缺陷有一个共同特征：**单测全绿，只有真机才暴露**。
/// 因为它们各自测各自的常量，没有任何一条断言检查「这些常量是否一致」。
///
/// 本文件专门补上这个横向约束。
library live_translate.test.language_registry_test;

import 'package:flutter_test/flutter_test.dart';

import 'package:live_translate/core/engine/llama_mt.dart';
import 'package:live_translate/core/engine/mock_asr.dart';
import 'package:live_translate/core/engine/mock_mt.dart';
import 'package:live_translate/core/engine/mt_engine.dart';
import 'package:live_translate/core/engine/sherpa_asr.dart';
import 'package:live_translate/core/i18n/language_registry.dart';
import 'package:live_translate/core/model/model_catalog.dart';
import 'package:live_translate/core/service/app_settings.dart';

void main() {
  group('LanguageRegistry 数据完整性', () {
    test('至少覆盖 9 种语言（v0.6.0 的识别模型数量是下限）', () {
      // 这不是「越多越好」的审美判断：每一种 AsrModelVariant 都对应一份
      // 用户能真下载到的模型，语言清单少一种就有人的模型白下。
      expect(LanguageRegistry.all.length, greaterThanOrEqualTo(9));
    });

    test('语言代码唯一（重复会让下拉框出现两个同 value 的 item）', () {
      final codes = LanguageRegistry.all.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length, reason: '存在重复语言代码');
    });

    test('每种语言的三个名称都非空', () {
      for (final language in LanguageRegistry.all) {
        expect(
          language.chineseName.trim(),
          isNotEmpty,
          reason: '${language.code} 缺中文名',
        );
        expect(
          language.nativeName.trim(),
          isNotEmpty,
          reason: '${language.code} 缺母语名',
        );
        expect(
          language.englishName.trim(),
          isNotEmpty,
          reason: '${language.code} 缺英文名（MT prompt 要用）',
        );
      }
    });

    test('语言代码是合法的小写 BCP-47 片段', () {
      // 大写代码会破坏持久化键的一致性（`EN` 与 `en` 是两个不同的 key）。
      final pattern = RegExp(r'^[a-z]{2,3}$');
      for (final language in LanguageRegistry.all) {
        expect(
          pattern.hasMatch(language.code),
          isTrue,
          reason: '${language.code} 不是合法的小写语言代码',
        );
      }
    });

    test('displayLabel 形如「中文名 (母语名)」', () {
      final zh = LanguageRegistry.byCode('ja');
      expect(zh, isNotNull);
      expect(zh!.displayLabel, '日语 (日本語)');
    });

    test('englishName 与 code 不混淆（MT prompt 必须写全称）', () {
      // 混元 / Qwen 的指令模板写 `Japanese` 才有稳定输出，写 `ja` 会乱。
      expect(LanguageRegistry.mtPromptName('ja'), 'Japanese');
      expect(LanguageRegistry.mtPromptName('zh'), 'Chinese');
      expect(LanguageRegistry.mtPromptName('ko'), 'Korean');
    });
  });

  group('LanguageRegistry 查询', () {
    test('byCode 命中所有已注册语言', () {
      for (final language in LanguageRegistry.all) {
        expect(LanguageRegistry.byCode(language.code)?.code, language.code);
        expect(LanguageRegistry.isKnown(language.code), isTrue);
      }
    });

    test('byCode 对未知 / null / 空串返回 null 而不是抛异常', () {
      // 持久化里完全可能残留一个「上一版认识、这一版删掉」的代码。
      // 那种情况必须能降级，不能白屏。
      expect(LanguageRegistry.byCode(null), isNull);
      expect(LanguageRegistry.byCode(''), isNull);
      expect(LanguageRegistry.byCode('xx'), isNull);
      expect(LanguageRegistry.isKnown('xx'), isFalse);
    });

    test('mtPromptName 对未知代码原样返回（不抛）', () {
      expect(LanguageRegistry.mtPromptName('xx'), 'xx');
    });

    test('displayLabel 对未知代码显示大写（不抛）', () {
      expect(LanguageRegistry.displayLabel('xx'), 'XX');
    });
  });

  group('LanguageRegistry 语言对', () {
    test('mtPairs 覆盖全部 n*(n-1) 个方向', () {
      final n = LanguageRegistry.all.length;
      expect(LanguageRegistry.mtPairs.length, n * (n - 1));
    });

    test('mtPairs 不含「自我翻译」方向', () {
      // 中文翻中文：模型会原样输出，对用户零价值，还白烧 CPU。
      for (final pair in LanguageRegistry.mtPairs) {
        expect(
          pair.source == pair.target,
          isFalse,
          reason: '${pair.source}→${pair.target} 是自我翻译',
        );
      }
    });

    test('mtPairs 里每个方向都唯一', () {
      final keys = LanguageRegistry.mtPairs
          .map((p) => '${p.source}->${p.target}')
          .toList();
      expect(keys.toSet().length, keys.length);
    });

    test('mtPairs 的 displayName 用英文全称（进 prompt 的是它）', () {
      final pair = LanguageRegistry.mtPairs.firstWhere(
        (p) => p.source == 'en' && p.target == 'ja',
      );
      expect(pair.displayName, 'English → Japanese');
    });
  });

  // ---------------------------------------------------------------------------
  // 下面的断言是「横向一致性」—— 本项目历史上最贵的缺陷就出在这里。
  // ---------------------------------------------------------------------------

  group('横向一致性：引擎必须认识注册表里的每一种语言', () {
    test('SherpaASREngine.supportedLanguages 覆盖全部注册语言', () {
      // 旧实现硬编码 9 种、漏掉 fr/de/es，用户切到 fr 直接抛 ArgumentError。
      final engine = SherpaASREngine();
      final supported = engine.supportedLanguages.toSet();
      for (final language in LanguageRegistry.all) {
        expect(
          supported.contains(language.code),
          isTrue,
          reason:
              'SherpaASR 不认识 ${language.code}，'
              '用户选到它会抛 ArgumentError',
        );
      }
    });

    test('MockASR.supportedLanguages 与真实引擎一致', () {
      // Mock 是「接口契约的参考实现」。它比真实引擎窄的话，
      // 单测通过、真机崩 —— 正是本项目的历史剧本。
      final mock = MockASR();
      final real = SherpaASREngine();
      expect(mock.supportedLanguages.toSet(), real.supportedLanguages.toSet());
    });

    test('LlamaMTEngine.supportedLanguagePairs 覆盖全部语言对', () {
      // 旧实现硬编码 11 个方向，en→ru 直接抛 ArgumentError。
      final engine = LlamaMTEngine();
      final supported = engine.supportedLanguagePairs
          .map((p) => '${p.source}->${p.target}')
          .toSet();
      for (final pair in LanguageRegistry.mtPairs) {
        expect(
          supported.contains('${pair.source}->${pair.target}'),
          isTrue,
          reason: 'LlamaMT 不支持 ${pair.source}→${pair.target}',
        );
      }
    });

    test('MockMT.supportedLanguagePairs 与真实引擎一致', () {
      final mock = MockMT();
      final real = LlamaMTEngine();
      String key(LanguagePair p) => '${p.source}->${p.target}';
      expect(
        mock.supportedLanguagePairs.map(key).toSet(),
        real.supportedLanguagePairs.map(key).toSet(),
      );
    });
  });

  group('横向一致性：每种语言都必须有可下载的识别模型', () {
    test('ModelCatalog.recommendedFor 覆盖全部注册语言', () {
      // 推荐函数用 switch 实现，漏一个语种会静默走 default 分支，
      // 用户下到的是「中英双语模型」却以为自己下的是法语模型。
      for (final language in LanguageRegistry.all) {
        final variant = ModelCatalog.recommendedFor(language.code);
        // 只断言「有推荐」不够 —— default 分支也会返回 zhEn。
        // 这里额外要求：推荐结果能真的组出四件套。
        expect(
          ModelCatalog.asrFilesFor(variant),
          isNotEmpty,
          reason: '${language.code} 推荐的 $variant 没有对应模型文件',
        );
      }
    });

    test('法语 / 德语 / 西班牙语 / 俄语 各自推荐到专用模型', () {
      // 这四个语种是 v0.6.0 新增的，也是最容易被漏掉的一批。
      expect(ModelCatalog.recommendedFor('fr'), AsrModelVariant.french);
      expect(ModelCatalog.recommendedFor('de'), AsrModelVariant.german);
      expect(ModelCatalog.recommendedFor('es'), AsrModelVariant.spanish);
      expect(ModelCatalog.recommendedFor('ru'), AsrModelVariant.russian);
    });

    test('未知语种仍退回中英双语（不抛异常）', () {
      expect(ModelCatalog.recommendedFor('xx'), AsrModelVariant.zhEn);
    });
  });

  group('横向一致性：持久化默认值必须在注册表里', () {
    setUp(() => AppSettingsStore.instance.debugReset());

    test('三个默认语言都被 LanguageRegistry 认识', () {
      // 默认值不在注册表里的话，新用户第一次打开就会看到
      // DropdownButton 的 value 断言失败（或渲染异常）。
      expect(
        LanguageRegistry.isKnown(AppSettingsStore.defaultAsrLanguage),
        isTrue,
      );
      expect(
        LanguageRegistry.isKnown(AppSettingsStore.defaultMtSourceLang),
        isTrue,
      );
      expect(
        LanguageRegistry.isKnown(AppSettingsStore.defaultMtTargetLang),
        isTrue,
      );
    });

    test('默认源语言与目标语言不同（否则一打开就是自我翻译）', () {
      expect(
        AppSettingsStore.defaultMtSourceLang,
        isNot(AppSettingsStore.defaultMtTargetLang),
      );
    });

    test('保存未知语言代码会被拒绝，保留原值', () async {
      // 白名单兜底：调用方传进来任意字符串也不能污染持久化。
      final store = AppSettingsStore.instance;
      await store.saveLanguages(asrLanguage: 'xx');
      expect(store.asrLanguage, AppSettingsStore.defaultAsrLanguage);

      await store.saveLanguages(mtTargetLang: 'zz');
      expect(store.mtTargetLang, AppSettingsStore.defaultMtTargetLang);
    });

    test('保存已知语言代码正常生效', () async {
      final store = AppSettingsStore.instance;
      await store.saveLanguages(asrLanguage: 'ja', mtTargetLang: 'ko');
      expect(store.asrLanguage, 'ja');
      expect(store.mtTargetLang, 'ko');
    });
  });
}
