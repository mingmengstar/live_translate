/// v0.7.1 真机 BUG 回归测试
///
/// 覆盖两个 P0：
/// - **BUG-1**：12 语种下拉框菜单过高且无法滚动 → 必须限制高度并固定项高
/// - **BUG-2**：悬浮窗失败原因不可定位 → 必须把 `error.code` 透出到 UI
///
/// 这两条断言都是「防止回退」性质：只要有人删掉 `menuMaxHeight` /
/// `itemHeight`，或把错误码又只存成一句中文，测试立刻红。
library live_translate.test.ui_regression_test;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:live_translate/core/service/translation_service.dart';
import 'package:live_translate/ui/home_screen.dart';
import 'package:live_translate/ui/main_screen.dart';

void main() {
  group('BUG-1 语言下拉框必须可滚动', () {
    testWidgets('三个下拉框都设置了 menuMaxHeight 与 itemHeight',
        (WidgetTester tester) async {
      final service = TranslationService();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: service,
          child: const MaterialApp(home: MainScreen()),
        ),
      );
      await tester.pump();

      final buttons = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .toList();

      // ASR 识别语言 / MT 源语言 / MT 目标语言
      expect(buttons.length, 3);

      for (final button in buttons) {
        // 不设 itemHeight 时 Flutter 会按内容撑高，menuMaxHeight 也就失效，
        // 12 个语种会把菜单顶出屏幕 —— 真机现象就是「滑不动」。
        expect(button.itemHeight, kDropdownItemHeight);
        expect(button.menuMaxHeight, kDropdownMenuMaxHeight);
      }

      // 参数本身也要合理：菜单最多显示约 6 项，且必须矮于常见竖屏可视区。
      expect(kDropdownItemHeight, greaterThan(0));
      expect(
        kDropdownMenuMaxHeight,
        greaterThanOrEqualTo(kDropdownItemHeight * 4),
      );
      expect(kDropdownMenuMaxHeight, lessThan(500));

      service.dispose();
    });

    testWidgets('长语言标签在固定项高下不溢出', (WidgetTester tester) async {
      final service = TranslationService();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: service,
          child: const MaterialApp(home: MainScreen()),
        ),
      );
      await tester.pump();

      // 语言卡片在首屏之外，必须先滚到可见位置再点。
      //
      // 不做这一步的后果（本轮实测踩到）：tap 的坐标落在渲染树之外，
      // Flutter 只打一条 warning 就跳过，菜单根本没打开 —— 断言看似通过，
      // 实际什么都没验证。这正是 HANDOVER 第 5 节记的「假阳性」那类问题。
      final dropdown = find.byType(DropdownButton<String>).first;
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();

      // 注意：`DropdownButton` 内部用 `IndexedStack` 承载了**全部** items，
      // 所以即使菜单没打开，页面上也已经存在一批 `DropdownMenuItem`。
      // 想判断「菜单真的展开了」，只能比对数量是否变多 ——
      // 展开时 `_DropdownRoute` 会把选中的那份 items 再渲染一遍到 Overlay 上。
      final before = find.byType(DropdownMenuItem<String>).evaluate().length;

      await tester.tap(dropdown, warnIfMissed: true);
      await tester.pumpAndSettle();

      final after = find.byType(DropdownMenuItem<String>).evaluate().length;
      expect(
        after,
        greaterThan(before),
        reason: '下拉菜单未真正展开，后续断言会变成假阳性',
      );

      // 菜单项必须是单行 + 省略，否则在 itemHeight 固定高度下会溢出。
      final itemTexts = tester.widgetList<Text>(
        find.descendant(
          of: find.byType(DropdownMenuItem<String>),
          matching: find.byType(Text),
        ),
      );
      expect(itemTexts, isNotEmpty);
      for (final text in itemTexts) {
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
      }

      service.dispose();
    });
  });

  group('BUG-2 悬浮窗失败必须可定位', () {
    test('未运行状态下重试返回专门的错误码', () async {
      final service = TranslationService();
      expect(service.isServiceRunning, false);

      final result = await service.retryOverlay();

      expect(result.ok, false);
      // 没有 code 的话，UI 只能显示一句中文，真机复测无法判断根因。
      expect(result.code, 'NOT_RUNNING');
      expect(result.reason, isNotNull);
    });

    test('初始状态不残留悬浮窗问题', () {
      final service = TranslationService();
      expect(service.overlayNote, isNull);
      expect(service.overlayErrorCode, isNull);
    });

    testWidgets('首页在无异常时不显示悬浮窗提示条',
        (WidgetTester tester) async {
      final service = TranslationService();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: service,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();

      expect(find.text('悬浮字幕未显示'), findsNothing);

      service.dispose();
    });
  });
}
