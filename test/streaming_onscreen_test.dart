/// v0.9.0「边出 token 边上屏」回归测试
///
/// ## 这个文件守护什么
///
/// 用户最强烈的诉求是「反应慢 / 一直转圈」：说一句话，屏幕要等一两秒才出现
/// 译文。根因很具体 —— `translation_service.dart` 里两处 `onChunk: (_) {}`
/// 把 MT 的中间 token 全丢了，译文只在**整次生成结束后**才上屏。
///
/// 把 `onChunk` 接上屏这件事本身很简单，但它会同时打开三个坑：
///
/// | 坑 | 症状 | 本文件对应断言 |
/// |---|---|---|
/// | 每次 token 都 insert 一条字幕 | 播报一句，历史里出现几十条同一句 | 「同一句只占一条」 |
/// | 过期推理的迟到 token 照样写屏 | 字幕来回跳、越跳越短 | 「旧 run 的 chunk 被丢弃」 |
/// | 定稿时写两次（流式 + commit） | 同一句重复出现两条 | 「定稿不产生重复条目」 |
///
/// 这三条都是**纯状态断言**，不需要模型、不需要平台通道，能在 `flutter test`
/// 里稳定跑。不要删。
library live_translate.test.streaming_onscreen_test;

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translate/core/engine/mock_mt.dart';
import 'package:live_translate/core/service/translation_service.dart';

void main() {
  group('MTChunk 语义契约', () {
    test('MockMT 的 chunk.text 是累计文本，不是增量', () async {
      // 这条守护的是接口语义。上层把 chunk.text 直接当字幕正文用，
      // 一旦某个实现改成发增量，屏幕就只会显示最后半截。
      final mt = MockMT();
      await mt.initialize(sourceLang: 'en', targetLang: 'ja');

      final seen = <String>[];
      await mt.translateStream(
        text: 'Hello',
        onChunk: (c) => seen.add(c.text),
        onComplete: (_) {},
        onError: (e, _) => fail('MT error: $e'),
      );

      expect(seen, isNotEmpty);
      // 累计的关键特征：后一个 chunk 必须以前一个为前缀。
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i].startsWith(seen[i - 1]),
          isTrue,
          reason: 'chunk 必须是累计文本：${seen[i - 1]} → ${seen[i]}',
        );
      }
      // 最后一个 chunk 就是完整译文
      expect(seen.last, contains('Hello'));
      await mt.dispose();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('字幕条目合并（防止一句变几十条）', () {
    test('同一句的多次部分译文只占一条历史', () {
      final service = TranslationService();
      // 直接驱动所有上屏路径的汇合点：token 级回调与定稿回调都走这里，
      // 所以在这里断言等价于断言整条链路。
      service.debugSeedSubtitle(
        sourceText: 'I want to',
        translatedText: '我想',
        isFinal: false,
      );
      service.debugSeedSubtitle(
        sourceText: 'I want to go',
        translatedText: '我想去',
        isFinal: false,
      );
      service.debugSeedSubtitle(
        sourceText: 'I want to go home',
        translatedText: '我想去回家',
        isFinal: false,
      );

      expect(
        service.subtitleBuffer.length,
        1,
        reason: '进行中的同一条字幕必须原地更新，不能每次 token 都插一条',
      );
      expect(service.subtitleBuffer.first.translatedText, '我想去回家');
      expect(service.subtitleBuffer.first.isFinal, isFalse);
      service.dispose();
    });

    test('定稿写入不会与最后一次流式写入重复', () {
      final service = TranslationService();
      service.debugSeedSubtitle(
        sourceText: 'I want to go home.',
        translatedText: '我想去回家。',
        isFinal: false,
      );
      service.debugSeedSubtitle(
        sourceText: 'I want to go home.',
        translatedText: '我想去回家。',
        isFinal: true,
      );

      expect(
        service.subtitleBuffer.length,
        1,
        reason: '定稿链路会写两次（流式 + commit），必须合并成一条',
      );
      expect(service.subtitleBuffer.first.isFinal, isTrue);
      service.dispose();
    });

    test('下一句会正常开新条目', () {
      final service = TranslationService();
      service.debugSeedSubtitle(
        sourceText: '第一句。',
        translatedText: '译文一。',
        isFinal: true,
      );
      service.debugSeedSubtitle(
        sourceText: '第二句',
        translatedText: '译文二',
        isFinal: false,
      );

      expect(service.subtitleBuffer.length, 2);
      expect(service.subtitleBuffer.first.sourceText, '第二句');
      expect(service.subtitleBuffer.last.sourceText, '第一句。');
      service.dispose();
    });

    test('原地更新时保留首次出现的时间戳', () {
      final service = TranslationService();
      service.debugSeedSubtitle(
        sourceText: '句子',
        translatedText: '译一',
        isFinal: false,
      );
      final firstSeen = service.subtitleBuffer.first.timestamp;

      service.debugSeedSubtitle(
        sourceText: '句子继续',
        translatedText: '译一继续',
        isFinal: false,
      );
      expect(service.subtitleBuffer.first.timestamp, firstSeen);
      service.dispose();
    });
  });

  group('过期推理的 chunk 必须被丢弃', () {
    test('旧 run 的 chunk 无法覆盖当前译文', () {
      final service = TranslationService();
      final current = service.debugCurrentRunId;

      // 过期的 run：必须被丢弃
      service.debugFeedChunk(
        runId: current - 1,
        text: '过期的旧译文',
        sourceText: 'I want to go',
      );
      expect(
        service.currentTranslatedPartial,
        isEmpty,
        reason: '已过期推理的 token 绝不能上屏，否则字幕会往回跳',
      );

      // 当前 run：必须被采纳
      service.debugFeedChunk(
        runId: current,
        text: '最新译文',
        sourceText: 'I want to go',
      );
      expect(service.currentTranslatedPartial, '最新译文');
      service.dispose();
    });

    test('重复内容的 chunk 不重复触发刷新', () {
      final service = TranslationService();
      final current = service.debugCurrentRunId;

      var notifications = 0;
      service.addListener(() => notifications++);

      service.debugFeedChunk(
        runId: current,
        text: '一样的译文',
        sourceText: 'same',
      );
      final afterFirst = notifications;

      // StreamRevise 会大段沿用上一版译文，相邻 chunk 常常完全相同。
      service.debugFeedChunk(
        runId: current,
        text: '一样的译文',
        sourceText: 'same',
      );

      expect(
        notifications,
        afterFirst,
        reason: '完全相同的部分译文不该再刷一次 UI',
      );
      service.dispose();
    });

    test('空 chunk 不上屏', () {
      final service = TranslationService();
      service.debugFeedChunk(
        runId: service.debugCurrentRunId,
        text: '   ',
        sourceText: 'x',
      );
      expect(service.currentTranslatedPartial, isEmpty);
      expect(service.subtitleBuffer, isEmpty);
      service.dispose();
    });
  });
}