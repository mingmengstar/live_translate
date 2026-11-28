/// v0.9.2 流式上屏节流语义守护
///
/// ## 这里守的是什么
///
/// 用户的核心验收标准是「边识别边部分翻译、一个字一个字出现」。
/// 这条链路上有一个**极易被误改回退**的点：
///
/// 主 App 把 MT 的 token 推给界面时要经过一层 100ms 的时间窗。
/// 该时间窗必须是**节流（throttle）**：计时器已在跑时只更新待推送值，
/// **不重置**计时器 —— 这样「最多每 100ms 必刷一次」。
///
/// 如果写成**防抖（debounce）**（每次调用都 cancel + 重开计时器），
/// 而 MT token 密集时每 30~80ms 就来一个，计时器就永远等不到安静期：
/// 整句生成完才一次性刷出来。屏幕观感就是「卡一下 → 整句蹦出来」，
/// 与「逐字出现」正好相反。
///
/// 这个 bug 在单测里很难靠行为断言抓到（需要精确控制多个异步计时器
/// 与 100ms 边界），但**源码结构**是确定的：那个 `return` 守卫一旦被
/// 删掉，语义必然退回防抖。所以这里用源码断言守住它。
///
/// 同时也守住「节流窗口必须是 100ms」这条防崩红线（勿调低）。
library live_translate.test.streaming_throttle_test;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translate/core/service/translation_service.dart';

/// 去掉 Dart 的 `//`、`///` 行注释与 `/* */` 块注释
///
/// 注释里大量出现「不要 reset 计时器」这类说明文字，
/// 不剥掉会让 `contains` 断言误判（本项目已踩过一次）。
String stripDartComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}

void main() {
  group('流式上屏必须是「节流」而不是「防抖」', () {
    late String service;

    setUpAll(() {
      service = stripDartComments(
        File('lib/core/service/translation_service.dart').readAsStringSync(),
      );
    });

    test('节流窗口必须存在「计时器已在跑就直接返回」的守卫', () {
      // 这一行就是节流与防抖的全部区别。
      // 删掉它 = 退回防抖 = 「整句一次性蹦出来」。
      expect(
        RegExp(
          r'if\s*\(\s*_debounceTimer\?\.isActive\s*\?\?\s*false\s*\)\s*return\s*;',
        ).hasMatch(service),
        true,
        reason: '缺少 isActive 守卫，100ms 窗口会退化成防抖，'
            'token 密集时永远等不到刷新 → 逐字上屏失效',
      );
    });

    test('节流窗口不得在每次调用时无条件重置计时器', () {
      // 旧实现（防抖）的特征：先 cancel 再重开。
      // 允许 cancel 出现在别处（如 _resetStreamingState 的收尾清理），
      // 但不允许它紧挨着 `_debounceTimer = Timer(` 出现。
      final resetPattern = RegExp(
        r'_debounceTimer\?\.cancel\(\)\s*;\s*_debounceTimer\s*=\s*Timer',
      );
      expect(
        resetPattern.hasMatch(service),
        false,
        reason: '出现了「先 cancel 再重开计时器」的防抖写法，'
            '会把逐字上屏重新变回整句一次性刷新',
      );
    });

    test('节流窗口必须是 100ms（防崩红线，勿调低）', () {
      expect(
        service.contains('Duration(milliseconds: 100)'),
        true,
        reason: '100ms 节流是硬约束：调低会高频重建 UI 与刷悬浮窗消息',
      );
      // 并且这一处必须就在调度函数里（而不是别处的无关 100ms）
      expect(
        RegExp(
          r'void _scheduleDebouncedUpdate\(\{[\s\S]{0,1200}?'
          r'Duration\(milliseconds: 100\)',
        ).hasMatch(service),
        true,
        reason: '调度函数里必须存在 100ms 的节流窗口',
      );
    });

    test('节流回调必须同时推到悬浮窗与 notifyListeners', () {
      // 只推悬浮窗不 notifyListeners，主界面「实时翻译」预览会整句才更新；
      // 只 notifyListeners 不推悬浮窗，悬浮窗会不动。两者缺一不可。
      final throttleBlock = RegExp(
        r'void _scheduleDebouncedUpdate\(\{[\s\S]{0,1600}?\}\);',
      ).firstMatch(service)?.group(0);
      expect(throttleBlock, isNotNull, reason: '找不到调度函数主体');
      expect(
        throttleBlock!.contains('_sendToOverlay()'),
        true,
        reason: '节流回调必须把字幕推给悬浮窗',
      );
      expect(
        throttleBlock.contains('notifyListeners()'),
        true,
        reason: '节流回调必须通知 UI 重建，否则主界面预览不逐字更新',
      );
    });
  });

  group('MTChunk 累计语义（改错会让屏幕只显示最后半截）', () {
    test('字幕写入必须经过 _addSubtitleEntry（同句合并的唯一入口）', () {
      final service = stripDartComments(
        File('lib/core/service/translation_service.dart').readAsStringSync(),
      );
      // 绕过它直接 insert 会让「一句变几十条」立刻复发
      final directInserts = RegExp(r'_subtitleBuffer\.insert\(').allMatches(service);
      // 允许 1 处：_addSubtitleEntry 内部的正常插入
      expect(
        directInserts.length,
        1,
        reason: '除 _addSubtitleEntry 之外不得直接往缓冲区插字幕',
      );
    });
  });

  group('ASR 端点参数（改小会让长句被切碎）', () {
    late String worker;

    setUpAll(() {
      worker = stripDartComments(
        File('lib/core/engine/sherpa_asr_worker.dart').readAsStringSync(),
      );
    });

    test('rule3MinUtteranceLength 不得低于 25 秒', () {
      // 50 个中文字正常语速要 12~20 秒。旧值 10 秒会拦腰截断长句，
      // 表现就是「说了 50 字只识别出 20 字」。
      final m = RegExp(r'rule3MinUtteranceLength:\s*([\d.]+)').firstMatch(worker);
      expect(m, isNotNull, reason: '找不到 rule3 配置');
      final seconds = double.parse(m!.group(1)!);
      expect(
        seconds,
        greaterThanOrEqualTo(25),
        reason: 'rule3 低于 25 秒会把正常中文长句强制截断，'
            '导致「一大段只识别出一小截」',
      );
    });

    test('rule1MinTrailingSilence 不得低于 1.2 秒', () {
      // 中文长句里的换气 / 选词停顿普遍 0.8~1.5 秒。
      // 旧值 0.8 会把一句话切成 3~4 段，每段都从零开始解码。
      final m =
          RegExp(r'rule1MinTrailingSilence:\s*([\d.]+)').firstMatch(worker);
      expect(m, isNotNull, reason: '找不到 rule1 配置');
      final seconds = double.parse(m!.group(1)!);
      expect(
        seconds,
        greaterThanOrEqualTo(1.2),
        reason: 'rule1 太短会把句中换气判成句末，一句话被切碎',
      );
    });
  });

  group('前文上下文长度（直接乘在每句的 prefill 延迟上）', () {
    test('上下文句数不得超过 3', () {
      // 每轮翻译都要把整段 prompt 重新 prefill。5 句中文约 300+ token，
      // 手机上光 prefill 就要 1.5~3 秒 —— 这是「翻译慢」的主因。
      expect(
        TranslationService.maxContextSentences,
        lessThanOrEqualTo(3),
        reason: '上下文句数超过 3 会让每句都多等 1 秒以上',
      );
      expect(TranslationService.maxContextSentences, greaterThan(0));
    });
  });
}