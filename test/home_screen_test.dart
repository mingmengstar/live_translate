/// 首页 / 模型状态 Widget 测试
///
/// 覆盖本轮 P0-1 改动：
/// - HomeScreen 能正常渲染（不依赖真实平台通道）
/// - 模型状态检测在测试环境下不崩溃，并给出"无法检测"语义
library live_translate.test.home_screen_test;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:live_translate/core/model/model_storage.dart';
import 'package:live_translate/core/service/translation_service.dart';
import 'package:live_translate/ui/home_screen.dart';

void main() {
  group('ModelStorage', () {
    test('必需文件清单覆盖 ASR / VAD / MT 三类', () {
      final kinds =
          ModelStorage.requiredFiles.map((f) => f.kind).toSet();
      expect(kinds.contains(ModelKind.asr), true);
      expect(kinds.contains(ModelKind.vad), true);
      expect(kinds.contains(ModelKind.mt), true);
    });

    test('文件名唯一', () {
      final names =
          ModelStorage.requiredFiles.map((f) => f.fileName).toList();
      expect(names.toSet().length, names.length);
    });

    test('空状态判定为未就绪', () {
      const status = ModelStatus(directoryPath: '/tmp', presentFiles: []);
      expect(status.isReady, false);
      expect(status.asrReady, false);
      expect(status.mtReady, false);
      expect(status.vadReady, false);
      expect(status.presentCount, 0);
    });

    test('ASR + MT 齐全即视为就绪（VAD 可选）', () {
      final status = ModelStatus(
        directoryPath: '/tmp',
        presentFiles: [
          ...ModelStorage.asrFileNames,
          ...ModelStorage.mtFileNames,
        ],
      );
      expect(status.asrReady, true);
      expect(status.mtReady, true);
      expect(status.vadReady, false);
      expect(status.isReady, true);
    });

    test('缺少 MT 模型时不算就绪', () {
      final status = ModelStatus(
        directoryPath: '/tmp',
        presentFiles: [...ModelStorage.asrFileNames],
      );
      expect(status.asrReady, true);
      expect(status.isReady, false);
    });

    test('检测失败时带回错误信息', () {
      const status = ModelStatus(
        directoryPath: '',
        presentFiles: [],
        error: 'MissingPluginException',
      );
      expect(status.hasError, true);
      expect(status.isReady, false);
    });
  });

  group('HomeScreen', () {
    testWidgets('首页渲染基础元素', (WidgetTester tester) async {
      final service = TranslationService();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: service,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();

      // 首屏可见部分
      expect(find.text('实时翻译'), findsOneWidget);
      expect(find.text('模型状态'), findsOneWidget);

      // 下方内容需滚动后才会被 ListView 懒加载
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(find.text('引擎状态'), findsOneWidget);
      expect(find.text('进入翻译控制台'), findsOneWidget);
      expect(find.text('模型管理与导入'), findsOneWidget);

      service.dispose();
    });

    testWidgets('首页展示 Mock 模式标签', (WidgetTester tester) async {
      final service = TranslationService();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: service,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();

      // 未初始化引擎 / Mock 引擎都应为 Mock 模式
      expect(find.text('Mock 模式'), findsOneWidget);

      service.dispose();
    });
  });
}