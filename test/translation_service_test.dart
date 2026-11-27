/// 翻译服务单元测试
/// 验证 Mock 引擎链路完整性
library live_translate.test.translation_service_test;

import 'package:flutter_test/flutter_test.dart';
// 精确到文件：Mock 实现已从 engine.dart 的 barrel 里移除
// （v0.5.0 起运行时不再注册 Mock 引擎），测试仍然需要它们来验证接口契约。
import 'package:live_translate/core/engine/asr_engine.dart';
import 'package:live_translate/core/engine/mock_asr.dart';
import 'package:live_translate/core/engine/mock_mt.dart';
import 'package:live_translate/core/engine/mt_engine.dart';

void main() {
  group('TranslationService', () {
    // Test 1: Mock ASR 引擎直接测试（避免单例冲突）
    test('MockASR 应产生模拟识别结果', () async {
      final mockAsr = MockASR();
      
      await mockAsr.initialize(language: 'en');
      expect(mockAsr.isInitialized, true);
      
      final results = <ASRResult>[];
      await mockAsr.start(
        onResult: (r) => results.add(r),
        onError: (e, s) => fail('ASR error: $e'),
      );
      
      // 等待几个定时器周期
      await Future.delayed(const Duration(milliseconds: 100));
      
      await mockAsr.stop();
      
      expect(results, isNotEmpty);
      expect(results.any((r) => r.isFinal), true);
    }, timeout: const Timeout(Duration(seconds: 10)));
    
    // Test 2: Mock MT 引擎直接测试
    test('MockMT 应产生带前缀的翻译结果', () async {
      final mockMt = MockMT();
      
      await mockMt.initialize(sourceLang: 'en', targetLang: 'ja');
      expect(mockMt.isInitialized, true);
      
      final chunks = <MTChunk>[];
      MTResult? finalResult;
      
      await mockMt.translateStream(
        text: 'Hello world',
        onChunk: (c) => chunks.add(c),
        onComplete: (r) => finalResult = r,
        onError: (e, s) => fail('MT error: $e'),
      );
      
      expect(chunks, isNotEmpty);
      expect(finalResult, isNotNull);
      expect(finalResult!.translatedText, startsWith('【日】'));
      expect(finalResult!.sourceText, 'Hello world');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}