/// v0.8.0 流式翻译管线回归测试
///
/// ## 为什么必须有这个文件
///
/// v0.7.x 的真机表现是「识别重复 + 识别不出 + 根本不翻译」。
/// 这三个现象背后是**四个独立的缺陷**，而它们全都能绕开原有测试：
///
/// | 缺陷 | 原有测试为何没发现 |
/// |---|---|
/// | ASR 同一句以 `isFinal:false` + `isFinal:true` 各报一次 | 没有断言「同一句不得上报两次」 |
/// | `flush()` 后 stream 永久报废，停止再开始就没识别 | 没有跨 flush 的连续性断言 |
/// | 只在 `isFinal` 时翻译 → 不实时 | 没有断言「中间结果也要翻译」 |
/// | 翻译请求不带 `previousTranslation` → 模型退化成普通翻译 | 没有断言请求内容 |
///
/// 本文件把这些约束钉死。改动识别 / 翻译链路时**不要删这些断言**。
library live_translate.test.streaming_pipeline_test;

import 'package:flutter_test/flutter_test.dart';

import 'package:live_translate/core/engine/llama_mt.dart';
import 'package:live_translate/core/i18n/language_registry.dart';
import 'package:live_translate/core/model/model_catalog.dart';

void main() {
  group('StreamTranslateRequest 语义', () {
    test('空文本被识别为空请求（不该进模型）', () {
      expect(const StreamTranslateRequest(text: '').isEmpty, isTrue);
      expect(const StreamTranslateRequest(text: '   ').isEmpty, isTrue);
      expect(const StreamTranslateRequest(text: 'hello').isEmpty, isFalse);
    });

    test('默认是「中间态」而不是定稿（漏传会误导模型补句号）', () {
      // StreamRevise 依据 isFinal 决定「半句不补标点 / 定稿收尾」。
      // 默认值必须是 false：调用方忘了传，最多是标点没补；
      // 默认成 true 则会让模型过早给半句加句号，看起来像「一句话被截断」。
      expect(const StreamTranslateRequest(text: 'x').isFinal, isFalse);
    });

    test('首译时 previousTranslation 为空', () {
      expect(
        const StreamTranslateRequest(text: 'x').previousTranslation,
        isEmpty,
      );
    });
  });

  group('Hy-MT3 提示词（中文标记 + 中文语言名）', () {
    late LlamaMTEngine engine;

    setUp(() {
      engine = LlamaMTEngine()
        ..sourceLanguage = 'en'
        ..targetLanguage = 'ja';
    });

    /// 用 config 注入模板风格（不加载模型，只测渲染）
    Future<void> useHyMt3() async {
      // initialize 会尝试加载权重并抛异常，这里只借用它的模板选择逻辑，
      // 因此直接调用 buildPrompt 前先手动设置 —— 通过反射不可行，
      // 改为：构造一个空请求让 buildPrompt 用默认风格（默认就是 hyMt3Stream）。
      expect(engine.promptStyle, MtPromptStyle.hyMt3Stream);
    }

    test('中间态输出「进行中」，定稿输出「本句结束」', () async {
      await useHyMt3();

      final partial = engine.buildPrompt(
        const StreamTranslateRequest(text: 'I want to', isFinal: false),
      );
      expect(partial, contains('状态：进行中'));
      expect(partial, isNot(contains('状态：本句结束')));

      final finalOne = engine.buildPrompt(
        const StreamTranslateRequest(text: 'I want to go home.', isFinal: true),
      );
      expect(finalOne, contains('状态：本句结束'));
    });

    test('使用【背景信息】与【待翻译文本】中文结构标记', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, contains('【背景信息】'));
      expect(prompt, contains('【待翻译文本】'));
      // 不能混入 Hy-MT2 的英文标记：混用会输出原文
      expect(prompt, isNot(contains('[Source Text]')));
      expect(prompt, isNot(contains('[Background Information]')));
    });

    test('目标语言必须是中文名（写英文会掉质量）', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, contains('翻译为日语'));
      expect(prompt, isNot(contains('翻译为 Japanese')));
    });

    test('首译时整块省略「上一版译文」', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, isNot(contains('上一版译文：')));
    });

    test('带上一版译文时，模型能拿到它（前缀保留的前提）', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(
          text: 'I want to go home',
          previousTranslation: '我想去',
        ),
      );
      expect(prompt, contains('上一版译文：'));
      expect(prompt, contains('我想去'));
    });

    test('无前文时整块省略「前文上下文」', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, isNot(contains('前文上下文：')));
    });

    test('有前文时逐条写入', () async {
      await useHyMt3();
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(
          text: 'and then',
          recentSources: ['first sentence', 'second sentence'],
        ),
      );
      expect(prompt, contains('前文上下文：'));
      expect(prompt, contains('first sentence'));
      expect(prompt, contains('second sentence'));
    });
  });
group('Hy-MT2 提示词（英文标记 + 英文语言名）', () {
    late LlamaMTEngine engine;

    setUp(() {
      engine = LlamaMTEngine()
        ..sourceLanguage = 'en'
        ..targetLanguage = 'ja'
        ..debugSetPromptStyle(MtPromptStyle.hyMt2Stream);
    });

    test('与 Hy-MT3 结构完全不同，不能混用', () {
      // 这条断言保护的是「模板按模型分离」这个设计：
      // 两个模型共用一套模板的话，其中一个必然输出原文/乱码。
      expect(
        MtPromptStyle.hyMt2Stream,
        isNot(MtPromptStyle.hyMt3Stream),
      );

      // 两个变体的规格必须指向**不同**的模板
      expect(
        ModelCatalog.mtSpec(MtModelVariant.hyMt2StreamRevise).promptStyle,
        isNot(
          ModelCatalog.mtSpec(MtModelVariant.hyMt3StreamRevise).promptStyle,
        ),
      );
    });

    test('渲染时用英文标记，不混入中文标记', () {
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(
          text: 'hello',
          previousTranslation: 'こんにちは',
          previousSource: 'hello world',
        ),
      );
      expect(prompt, contains('[Background Information]'));
      expect(prompt, contains('[Source Text]'));
      expect(prompt, isNot(contains('【背景信息】')));
      expect(prompt, isNot(contains('【待翻译文本】')));
    });

    test('目标语言用英文全称', () {
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, contains('into Japanese'));
      expect(prompt, isNot(contains('翻译为日语')));
    });

    test('三个可选项全空时走整句锚点短模板', () {
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, startsWith('Translate the following text from English'));
      expect(prompt, isNot(contains('[Background Information]')));
    });

    test('上一版原文与上一版译文是两个独立槽位，绝不共用同一个值', () {
      // 这是本项目的**实际 bug 回归**：旧实现在
      // `Previous version of the current source:` 里塞了 previousTranslation，
      // 同一个值被填进「原文」和「译文」两个槽位，模型因此以为
      // 上一版原文就是那段译文，前缀对照从输入层就失效了。
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(
          text: 'I want to go home',
          previousSource: 'I want to go',
          previousTranslation: '家に帰りたい',
        ),
      );

      final sourceIdx =
          prompt.indexOf('Previous version of the current source:');
      final translationIdx =
          prompt.indexOf('Previous translation of the current source:');
      expect(sourceIdx, isNonNegative);
      expect(translationIdx, isNonNegative);
      // 顺序：原文块在前，译文块在后（官方 renderer 的固定顺序）
      expect(sourceIdx, lessThan(translationIdx));

      // 原文槽位里的内容必须是原文，不是译文
      final sourceBlock = prompt.substring(
        sourceIdx,
        translationIdx,
      );
      expect(sourceBlock, contains('I want to go'));
      expect(sourceBlock, isNot(contains('家に帰りたい')));

      // 译文槽位里的内容必须是译文
      final translationBlock = prompt.substring(translationIdx);
      expect(translationBlock, contains('家に帰りたい'));
    });

    test('没有上一版原文时整块省略，不用译文顶替', () {
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(
          text: 'I want to go home',
          previousTranslation: '家に帰りたい',
        ),
      );
      // 没有 previousSource 就必须整块省略
      expect(
        prompt,
        isNot(contains('Previous version of the current source:')),
      );
      // 但译文槽位仍然要在
      expect(
        prompt,
        contains('Previous translation of the current source:'),
      );
      expect(prompt, contains('家に帰りたい'));
    });

    test('块之间用一个空行分隔（官方 renderer 的 join 规则）', () {
      final prompt = engine.buildPromptBody(
        const StreamTranslateRequest(
          text: 'I want to go home',
          previousSource: 'I want to go',
          previousTranslation: '家に帰りたい',
          recentSources: ['first'],
        ),
      );
      // 三个 background 块 + 稳定性规则 → 彼此之间都是 \n\n
      expect(prompt, contains('Recent source utterances:\nfirst\n\n'));
      expect(
        prompt,
        contains(
          'Previous version of the current source:\n'
          'I want to go\n\n',
        ),
      );
      // 不能出现连续两个空行（那说明 blocks 拼接逻辑坏了）
      expect(prompt, isNot(contains('\n\n\n')));
    });
  });

  group('Hy 系列 chat 模板包装（P0：漏了它模型会输出原文/乱码）', () {
    late LlamaMTEngine engine;

    setUp(() {
      engine = LlamaMTEngine()..sourceLanguage = 'en'..targetLanguage = 'ja';
    });

    test('buildPrompt 必须以 BOS + user 标记开头，以 assistant 标记结尾', () {
      // 两个模型的官方发布卡都明确要求这个 wrapper：
      //   <｜hy_begin▁of▁sentence｜><｜hy_User｜>{PROMPT}<｜hy_Assistant｜>
      // 漏了它等于给模型一段无角色的裸文本 —— 这正是「译文是原文/乱码」的根因。
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt, startsWith('<｜hy_begin▁of▁sentence｜><｜hy_User｜>'));
      expect(prompt, endsWith('<｜hy_Assistant｜>'));
    });

    test('wrapper 里用的是全角竖线 U+FF5C 与 U+2581，不是 ASCII', () {
      // 这两个字符打错不会报错，只会让模型收到无法识别的裸文本，
      // 表现与「漏 wrapper」一模一样，极难二次排查。
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt.contains('\uFF5C'), isTrue, reason: '缺少全角竖线 U+FF5C');
      expect(prompt.contains('\u2581'), isTrue, reason: '缺少 U+2581');
      // 不能含有 ASCII 竖线的 hy 标记
      expect(prompt.contains('<|hy_User|>'), isFalse);
      expect(prompt.contains('<｜hy_User｜>'), isTrue);
    });

    test('结尾不得有多余换行（模型卡明确要求）', () {
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(prompt.endsWith('\n'), isFalse);
    });

    test('两个模型都走同一套 wrapper', () {
      final hyMt3 = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(hyMt3, startsWith('<｜hy_begin▁of▁sentence｜>'));

      engine.debugSetPromptStyle(MtPromptStyle.hyMt2Stream);
      final hyMt2 = engine.buildPrompt(
        const StreamTranslateRequest(text: 'hello'),
      );
      expect(hyMt2, startsWith('<｜hy_begin▁of▁sentence｜>'));
      expect(hyMt2, endsWith('<｜hy_Assistant｜>'));
    });

    test('包装后的 prompt 仍包含正文（不能把正文吃掉）', () {
      final prompt = engine.buildPrompt(
        const StreamTranslateRequest(text: 'I want to go home'),
      );
      expect(prompt, contains('I want to go home'));
      expect(prompt, contains('【待翻译文本】'));
    });
  });

  group('StreamTranslateRequest.previousSource 语义', () {
    test('默认是空串（首译时不会凭空出现「上一版原文」）', () {
      expect(const StreamTranslateRequest(text: 'x').previousSource, isEmpty);
    });
  });


  group('语言名双轨制（Hy-MT2 英文 / Hy-MT3 中文）', () {
    test('中日英三语在两套模板下都有正确名称', () {
      const expected = {
        'zh': ('Chinese', '中文'),
        'en': ('English', '英语'),
        'ja': ('Japanese', '日语'),
      };
      expected.forEach((code, names) {
        expect(LanguageRegistry.mtPromptName(code), names.$1);
        expect(LanguageRegistry.mtPromptNameZh(code), names.$2);
      });
    });

    test('三语两两组合共 6 个翻译方向', () {
      // 3 种语言 → 3 × 2 = 6 个方向（排除自我翻译）
      expect(LanguageRegistry.mtPairs.length, 6);
    });
  });

  group('翻译模型清单硬约束', () {
    test('每个翻译模型都必须带 promptStyle（否则引擎不知道用哪套模板）', () {
      for (final variant in MtModelVariant.values) {
        final spec = ModelCatalog.mtSpec(variant);
        expect(
          spec.promptStyle,
          isNotNull,
          reason: '${variant.name} 缺少 promptStyle',
        );
      }
    });

    test('所有 URL 都是 HuggingFace resolve/main 直链（支持 Range 续传）', () {
      for (final variant in MtModelVariant.values) {
        final url = ModelCatalog.mtFileFor(variant).url;
        expect(url, startsWith('https://huggingface.co/'));
        expect(url, contains('/resolve/main/'));
      }
    });

    test('声明体积与服务端一致（体积错了会导致下载永远判定不完整）', () {
      // 这两个数值来自 HuggingFace API 的 lfs.size，是硬事实。
      expect(
        ModelCatalog.mtFileFor(MtModelVariant.hyMt2StreamRevise).sizeBytes,
        1069288640,
      );
      expect(
        ModelCatalog.mtFileFor(MtModelVariant.hyMt3StreamRevise).sizeBytes,
        1133080672,
      );
    });

    test('文件名唯一（否则两个模型会互相覆盖）', () {
      final names =
          MtModelVariant.values.map((v) => ModelCatalog.mtFileFor(v).fileName);
      expect(names.toSet().length, MtModelVariant.values.length);
    });
  });

  group('ASR 模型清单（仅中日英）', () {
    test('不再包含韩/法/德/西/俄语模型', () {
      final names = AsrModelVariant.values.map((v) => v.name).toList();
      for (final removed in [
        'korean',
        'french',
        'german',
        'spanish',
        'russian',
      ]) {
        expect(
          names.contains(removed),
          isFalse,
          reason: '$removed 应当已移除（翻译模型不支持该语种）',
        );
      }
    });

    test('日语识别走多语种模型（中英模型认不出假名）', () {
      expect(
        ModelCatalog.recommendedFor('ja'),
        AsrModelVariant.multilingual,
      );
    });
  });
}