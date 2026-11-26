/// 真实引擎降级行为测试
///
/// 覆盖本轮新增的两个真实引擎（SherpaASR / LlamaMT）在
/// **没有模型文件** 时的行为：
/// - 必须抛异常（不能静默返回一个「假装初始化成功」的实例）
/// - 异常信息必须可读（告诉用户缺什么）
/// - 不能因为原生库缺失 / 平台通道不可用而崩溃
///
/// 为什么不测「加载成功」：
/// 真实推理需要 ~200MB 识别模型 + ~1.06GB 翻译权重，
/// 不可能进 CI 仓库（见 `.gitignore` / `assets/models/.gitkeep` 说明）。
/// 加载成功路径由真机验证覆盖（项目所有者执行）。
library live_translate.test.engine_fallback_test;

import 'package:flutter_test/flutter_test.dart';

import 'package:live_translate/core/engine/engine.dart';

void main() {
  group('SherpaASREngine 降级', () {
    test('模型缺失时 initialize 抛异常且信息可读', () async {
      final engine = SherpaASREngine();

      expect(engine.engineId, 'sherpa_asr');
      expect(engine.isInitialized, false);

      // 测试环境没有模型文件，必须抛异常而不是假装成功
      await expectLater(
        () => engine.initialize(language: 'en'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            anyOf(contains('缺少模型文件'), contains('模型')),
          ),
        ),
      );

      // 失败后不能残留 isInitialized = true
      expect(engine.isInitialized, false);
      expect(engine.isModelReady, false);

      // lastError 必须被填上，UI 才能展示原因
      expect(engine.lastError, isNotNull);

      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('未初始化时 start 抛异常', () async {
      final engine = SherpaASREngine();
      await expectLater(
        () => engine.start(
          onResult: (_) {},
          onError: (_, _) {},
        ),
        throwsA(isA<StateError>()),
      );
      await engine.dispose();
    });

    test('不支持的语言抛 ArgumentError', () async {
      final engine = SherpaASREngine();
      await expectLater(
        () => engine.switchLanguage('xx'),
        throwsA(isA<ArgumentError>()),
      );
      await engine.dispose();
    });

    test('getStatus 在未初始化时也可安全调用', () async {
      final engine = SherpaASREngine();
      final status = engine.getStatus();
      expect(status['engineId'], 'sherpa_asr');
      expect(status['isInitialized'], false);
      expect(status['modelReady'], false);
      await engine.dispose();
    });
  });

  group('LlamaMTEngine 降级', () {
    test('模型缺失时 initialize 抛异常且信息可读', () async {
      final engine = LlamaMTEngine();

      expect(engine.engineId, 'llama_mt');
      expect(engine.isInitialized, false);

      await expectLater(
        () => engine.initialize(sourceLang: 'en', targetLang: 'ja'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('翻译模型'),
          ),
        ),
      );

      expect(engine.isInitialized, false);
      expect(engine.isModelReady, false);
      expect(engine.lastError, isNotNull);

      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('未就绪时 translateStream 走 onError 而不是抛异常', () async {
      final engine = LlamaMTEngine();

      Object? captured;
      await engine.translateStream(
        text: 'hello',
        onChunk: (_) {},
        onComplete: (_) {},
        onError: (error, _) => captured = error,
      );

      expect(captured, isA<StateError>());
      await engine.dispose();
    });

    test('不支持的语言对抛 ArgumentError', () async {
      final engine = LlamaMTEngine();
      await expectLater(
        () => engine.switchLanguagePair('en', 'xx'),
        throwsA(isA<ArgumentError>()),
      );
      await engine.dispose();
    });

    test('getStatus 在未初始化时也可安全调用', () async {
      final engine = LlamaMTEngine();
      final status = engine.getStatus();
      expect(status['engineId'], 'llama_mt');
      expect(status['isInitialized'], false);
      expect(status['modelReady'], false);
      await engine.dispose();
    });
  });

  group('EngineManager 真实引擎注册', () {
    test('可以注册并在模型缺失时切换失败（不崩溃）', () async {
      final manager = EngineManager();

      manager.registerASREngine(
        SherpaASREngine.kEngineId,
        () => SherpaASREngine(),
      );
      manager.registerMTEngine(
        LlamaMTEngine.kEngineId,
        () => LlamaMTEngine(),
      );

      expect(
        manager.getRegisteredASREngines(),
        contains(SherpaASREngine.kEngineId),
      );
      expect(
        manager.getRegisteredMTEngines(),
        contains(LlamaMTEngine.kEngineId),
      );

      // 没有模型：切换必须返回 false（EngineManager 内部 catch 并 dispose）
      // 而不是把异常抛给上层
      final asrOk = await manager.switchASREngine(
        engineId: SherpaASREngine.kEngineId,
      );
      expect(asrOk, false);
      expect(manager.currentASRId, isNull);

      final mtOk = await manager.switchMTEngine(
        engineId: LlamaMTEngine.kEngineId,
      );
      expect(mtOk, false);
      expect(manager.currentMTId, isNull);

      await manager.disposeAll();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}