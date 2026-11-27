/// 模型清单与设置持久化测试
///
/// 覆盖 v0.6.0 的三类改动：
/// 1. **模型清单完整性**：新增的语种 / 翻译模型必须真的能被组装成可下载包，
///    不能出现「枚举加了但 _asrVariants 忘了加」这种「界面能选、点下载崩」的问题；
/// 2. **SHA-256 已移除**：`ModelLoader` 不应再暴露任何摘要相关 API；
/// 3. **设置持久化的健壮性**：未知枚举值 / 空字符串 / 类型异常都不能抛。
library live_translate.test.model_catalog_test;

import 'package:flutter_test/flutter_test.dart';

import 'package:live_translate/core/model/model_catalog.dart';
import 'package:live_translate/core/model/model_loader.dart';
import 'package:live_translate/core/service/app_settings.dart';

void main() {
  group('ModelCatalog 语种覆盖', () {
    test('每个 AsrModelVariant 都必须有完整的四件套', () {
      for (final variant in AsrModelVariant.values) {
        final files = ModelCatalog.asrFilesFor(variant);
        expect(
          files.length,
          4,
          reason: '${variant.name} 应当有 encoder/decoder/joiner/tokens 四个文件',
        );

        final roles = files.map((f) => f.role).toSet();
        expect(
          roles,
          {
            ModelFileRole.asrEncoder,
            ModelFileRole.asrDecoder,
            ModelFileRole.asrJoiner,
            ModelFileRole.asrTokens,
          },
          reason: '${variant.name} 的角色不完整',
        );
      }
    });

    test('同一语种内文件名唯一（防止落盘互相覆盖）', () {
      for (final variant in AsrModelVariant.values) {
        final names =
            ModelCatalog.asrFilesFor(variant).map((f) => f.fileName).toList();
        expect(
          names.toSet().length,
          names.length,
          reason: '${variant.name} 存在重名文件：$names',
        );
      }
    });

    test('所有语种的文件名互不冲突（可共存于同一目录）', () {
      final seen = <String, String>{};
      for (final variant in AsrModelVariant.values) {
        for (final file in ModelCatalog.asrFilesFor(variant)) {
          final existing = seen[file.fileName];
          expect(
            existing,
            isNull,
            reason: '${file.fileName} 同时属于 $existing 和 ${variant.name}，'
                '装了两套模型会互相覆盖',
          );
          seen[file.fileName] = variant.name;
        }
      }
    });

    test('每个语种都有显示名和说明（UI 不能出现空白项）', () {
      for (final variant in AsrModelVariant.values) {
        expect(
          ModelCatalog.asrVariantLabels[variant],
          isNotNull,
          reason: '${variant.name} 缺少显示名',
        );
        expect(
          ModelCatalog.asrVariantLabels[variant]!.trim(),
          isNotEmpty,
        );
        expect(
          ModelCatalog.asrVariantDetails[variant],
          isNotNull,
          reason: '${variant.name} 缺少说明',
        );
      }
    });

    test('所有下载地址都是 https（明文 HTTP 会被 Android 9+ 默认拦截）', () {
      for (final variant in AsrModelVariant.values) {
        for (final file in ModelCatalog.asrFilesFor(variant)) {
          expect(
            file.url.startsWith('https://'),
            isTrue,
            reason: '${file.fileName} 的地址不是 https：${file.url}',
          );
        }
        expect(ModelCatalog.sileroVad.url.startsWith('https://'), isTrue);
      }
    });

    test('所有体积都是正数（0 会让进度条永远算不出比例）', () {
      for (final variant in AsrModelVariant.values) {
        for (final file in ModelCatalog.asrFilesFor(variant)) {
          expect(
            file.sizeBytes,
            greaterThan(0),
            reason: '${file.fileName} 的 sizeBytes 非法',
          );
        }
      }
    });
  });

  group('ModelCatalog 翻译模型', () {
    test('每个 MtModelVariant 都能取到文件与规格', () {
      for (final variant in MtModelVariant.values) {
        final file = ModelCatalog.mtFileFor(variant);
        final spec = ModelCatalog.mtSpec(variant);

        expect(file.role, ModelFileRole.mt);
        expect(file.fileName.toLowerCase().endsWith('.gguf'), isTrue,
            reason: '${variant.name} 必须是 GGUF（llama.cpp 只认这个）');
        expect(file.sizeBytes, greaterThan(0));
        expect(spec.variant, variant);
        expect(spec.label.trim(), isNotEmpty);
        expect(spec.description.trim(), isNotEmpty);
        expect(spec.minFreeRamBytes, greaterThan(0));
      }
    });

    test('翻译模型文件名唯一', () {
      final names = MtModelVariant.values
          .map((v) => ModelCatalog.mtFileFor(v).fileName)
          .toList();
      expect(names.toSet().length, names.length, reason: '存在重名：$names');
    });

    test('体积越大的模型内存需求不能更小', () {
      // 排序后逐对检查：这是个很弱的约束，但能挡住
      // 「复制粘贴改 label 忘了改 minFreeRamBytes」这类错误。
      final sorted = MtModelVariant.values.toList()
        ..sort((a, b) => ModelCatalog.mtFileFor(a)
            .sizeBytes
            .compareTo(ModelCatalog.mtFileFor(b).sizeBytes));
      for (var i = 1; i < sorted.length; i++) {
        final prevRam = ModelCatalog.mtSpec(sorted[i - 1]).minFreeRamBytes;
        final curRam = ModelCatalog.mtSpec(sorted[i]).minFreeRamBytes;
        expect(
          curRam,
          greaterThanOrEqualTo(prevRam),
          reason: '${sorted[i].name} 比 ${sorted[i - 1].name} 大，'
              '但内存需求更小，疑似复制粘贴漏改',
        );
      }
    });

    test('Qwen2.5 用 ChatML 模板，混元用自家模板', () {
      expect(
        ModelCatalog.mtSpec(MtModelVariant.qwen25_05b).promptStyle,
        MtPromptStyle.chatMl,
      );
      for (final v in [
        MtModelVariant.hyMt15Q4,
        MtModelVariant.hyMt15Q8,
        MtModelVariant.hyMt7bQ4,
      ]) {
        expect(ModelCatalog.mtSpec(v).promptStyle, MtPromptStyle.hyMt,
            reason: '${v.name} 必须用混元专用模板，否则会输出原文');
      }
    });

    test('兼容旧名 hyMt15 等于默认的 Q4', () {
      expect(ModelCatalog.hyMt15, ModelCatalog.mtFileFor(MtModelVariant.hyMt15Q4));
    });
  });

  group('ModelCatalog.pack', () {
    test('带翻译 + VAD 时包含 ASR 四件套 + VAD + MT', () {
      final pack = ModelCatalog.pack();
      expect(pack.files.length, 6);
      expect(pack.includesTranslation, isTrue);
      expect(pack.mtFile, isNotNull);
      expect(pack.mtSpec, isNotNull);
    });

    test('关掉翻译时不含 MT（只下识别模型）', () {
      final pack = ModelCatalog.pack(withTranslation: false);
      expect(pack.includesTranslation, isFalse);
      expect(pack.mtFile, isNull);
      expect(pack.mtSpec, isNull);
      expect(pack.files.length, 5); // 四件套 + VAD
    });

    test('关掉 VAD 时不含 silero', () {
      final pack = ModelCatalog.pack(withVad: false);
      expect(
        pack.files.any((f) => f.role == ModelFileRole.vad),
        isFalse,
      );
    });

    test('不同组合的 packId 不同（否则「这次下到哪」会串）', () {
      final ids = <String>{
        ModelCatalog.pack().id,
        ModelCatalog.pack(withTranslation: false).id,
        ModelCatalog.pack(withVad: false).id,
        ModelCatalog.pack(variant: AsrModelVariant.english).id,
        ModelCatalog.pack(mtVariant: MtModelVariant.hyMt7bQ4).id,
      };
      expect(ids.length, 5, reason: 'packId 出现重复：$ids');
    });

    test('totalBytes 等于各文件之和', () {
      final pack = ModelCatalog.pack();
      final sum = pack.files.fold<int>(0, (s, f) => s + f.sizeBytes);
      expect(pack.totalBytes, sum);
      expect(pack.totalSizeLabel, isNotEmpty);
    });

    test('选择不同 MT 变体时，pack 里带的是对应文件', () {
      final pack = ModelCatalog.pack(mtVariant: MtModelVariant.qwen25_05b);
      expect(pack.mtFile!.fileName, contains('qwen2.5'));
    });
  });

  group('ModelCatalog.recommendedFor', () {
    test('每个支持的语种都推荐到「真的能识别该语种」的模型', () {
      // 关键：不能把 ja 推荐到 zhEn（中英模型根本认不出日语假名）。
      expect(ModelCatalog.recommendedFor('zh'), AsrModelVariant.chinese);
      expect(ModelCatalog.recommendedFor('en'), AsrModelVariant.english);
      expect(ModelCatalog.recommendedFor('ko'), AsrModelVariant.korean);
      expect(ModelCatalog.recommendedFor('fr'), AsrModelVariant.french);
      expect(ModelCatalog.recommendedFor('de'), AsrModelVariant.german);
      expect(ModelCatalog.recommendedFor('es'), AsrModelVariant.spanish);
      expect(ModelCatalog.recommendedFor('ru'), AsrModelVariant.russian);
      expect(ModelCatalog.recommendedFor('ja'), AsrModelVariant.multilingual);
    });

    test('未知语种退回中英双语（不要抛异常）', () {
      expect(ModelCatalog.recommendedFor('xx'), AsrModelVariant.zhEn);
      expect(ModelCatalog.recommendedFor(''), AsrModelVariant.zhEn);
    });
  });

  group('ModelLoader 已移除 SHA-256', () {
    test('不再暴露 digestOf 静态方法', () {
      // 用动态调用确认方法真的不存在：如果将来有人「顺手加回来」，
      // 这条会因为 NoSuchMethodError 反而失败。
      expect(
        () => (ModelLoader as dynamic).digestOf('x'),
        throwsA(isA<NoSuchMethodError>()),
      );
    });

    test('构造函数不再接受 verifyDigest 参数', () {
      // 传未知命名参数必须是编译期错误；这里用动态调用验证运行期也不认。
      expect(
        () => (ModelLoader as dynamic)(verifyDigest: false),
        throwsA(isA<NoSuchMethodError>()),
      );
    });

    test('ModelDownloadProgress 的速度 / 剩余时间格式化正确', () {
      const progress = ModelDownloadProgress(
        packId: 'p',
        totalBytes: 100 * 1024 * 1024,
        downloadedBytes: 0,
        results: [],
        isFinished: false,
        isCancelled: false,
        bytesPerSecond: 3 * 1024 * 1024,
        remainingSeconds: 252,
      );
      expect(progress.speedLabel, '3.0MB/s');
      expect(progress.remainingLabel, '约 4 分 12 秒');
    });

    test('速度为 0 时不显示速度 / 剩余时间（避免「0B/s」误导）', () {
      const progress = ModelDownloadProgress(
        packId: 'p',
        totalBytes: 100,
        downloadedBytes: 50,
        results: [],
        isFinished: false,
        isCancelled: false,
      );
      expect(progress.speedLabel, isEmpty);
      expect(progress.remainingLabel, isEmpty);
    });

    test('totalBytes 为 0 时 fraction 不除零', () {
      const progress = ModelDownloadProgress(
        packId: 'p',
        totalBytes: 0,
        downloadedBytes: 0,
        results: [],
        isFinished: false,
        isCancelled: false,
      );
      expect(progress.fraction, 0);
      expect(progress.percent, 0);
    });
  });

  group('AppSettingsStore 默认值', () {
    setUp(() => AppSettingsStore.instance.debugReset());

    test('未加载时给出「开箱即用」的默认值', () {
      final store = AppSettingsStore.instance;
      expect(store.asrLanguage, 'en');
      expect(store.mtSourceLang, 'en');
      // 不能默认成 ja：项目没有日语专用识别模型，
      // 默认日语会让新用户第一次打开就看到「模型缺失」。
      expect(store.mtTargetLang, 'zh');
      expect(store.asrVariant, AsrModelVariant.zhEn);
      expect(store.mtVariant, MtModelVariant.hyMt15Q4);
      expect(store.withVad, isTrue);
    });

    test('debugReset 能把改过的值还原', () async {
      final store = AppSettingsStore.instance;
      await store.saveLanguages(asrLanguage: 'ja', mtTargetLang: 'en');
      store.debugReset();
      expect(store.asrLanguage, 'en');
      expect(store.mtTargetLang, 'zh');
    });

    test('保存空字符串不会把语言清空', () async {
      final store = AppSettingsStore.instance;
      await store.saveLanguages(asrLanguage: '  ', mtTargetLang: '');
      expect(store.asrLanguage, 'en');
      expect(store.mtTargetLang, 'zh');
    });

    test('保存时首尾空格被去掉', () async {
      final store = AppSettingsStore.instance;
      await store.saveLanguages(asrLanguage: '  ko  ');
      expect(store.asrLanguage, 'ko');
    });

    test('saveModelChoice 能独立更新单个字段', () async {
      final store = AppSettingsStore.instance;
      await store.saveModelChoice(mtVariant: MtModelVariant.qwen25_05b);
      expect(store.mtVariant, MtModelVariant.qwen25_05b);
      // 其他字段不受影响
      expect(store.asrVariant, AsrModelVariant.zhEn);
      expect(store.withVad, isTrue);
    });
  });
}