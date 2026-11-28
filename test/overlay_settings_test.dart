/// 悬浮窗设置与双向协议的单测
///
/// ## 为什么这些能测、而那些不能
///
/// 真正的窗口操作（showOverlay / closeOverlay）依赖 Android 的
/// WindowManager 和前台服务，`flutter test` 里完全没有平台通道，
/// 想「测」只能造假通道，测出来的东西和真机行为没多大关系。
///
/// 但这次改动真正容易出错的地方**不是**平台调用，而是：
/// 1. 设置的状态迁移（字号到顶还能不能加、透明度找不到档位怎么办）；
/// 2. 两端对协议字段的解析是否一致（overlay 和主 App 是两个引擎，
///    编译器不会帮我们检查字段名对不上）；
/// 3. `fromMap` 的类型健壮性（JSONMessageCodec 会把整数值解码成 int，
///    直接 `as double` 会抛异常 —— 这个坑项目里踩过一次）。
///
/// 这三类都是纯函数，能测且有价值。所以本文件聚焦它们。
library live_translate.test.overlay_settings_test;

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translate/core/overlay/overlay_protocol.dart';
import 'package:live_translate/core/overlay/overlay_settings.dart';

void main() {
  group('OverlaySettings 字号迁移', () {
    test('默认字号是 16', () {
      expect(const OverlaySettings().fontSize, 16.0);
    });

    test('字号 +1 / -1 正常步进', () {
      const s = OverlaySettings(fontSize: 16);
      expect(s.withLargerFont.fontSize, 17.0);
      expect(s.withSmallerFont.fontSize, 15.0);
    });

    test('字号到上限后不再增加（clamp 住）', () {
      const s = OverlaySettings(fontSize: OverlaySettings.maxFontSize);
      expect(s.withLargerFont.fontSize, OverlaySettings.maxFontSize);
      expect(s.canIncreaseFont, false);
    });

    test('字号到下限后不再减小', () {
      const s = OverlaySettings(fontSize: OverlaySettings.minFontSize);
      expect(s.withSmallerFont.fontSize, OverlaySettings.minFontSize);
      expect(s.canDecreaseFont, false);
    });
  });

  group('OverlaySettings 透明度循环', () {
    test('按固定档位循环，且能绕回第一档', () {
      // v0.9.2：档位改为 [0.25, 0.4, 0.6, 0.8, 1.0]，默认 1.0（不透明）。
      // 从默认值连续点 5 次应该完整绕一圈回到原点。
      var s = const OverlaySettings();
      expect(s.opacity, 1.0, reason: '默认必须是不透明，否则可能"看不见"');

      final seen = <double>[];
      for (var i = 0; i < 5; i++) {
        s = s.withNextOpacity;
        seen.add(s.opacity);
      }
      expect(seen, [0.25, 0.4, 0.6, 0.8, 1.0]);
    });

    test('档位必须包含 0.25 这种「几乎全透明」的极端值', () {
      // 用户的核心诉求是「太挡视线了就再透明点」。
      // 旧档位最低 0.6，在小屏上仍然盖住小半个屏幕，等于没得选。
      expect(OverlaySettings.opacityLevels.first, 0.25);
      expect(OverlaySettings.minOpacity, 0.25);
      // 但不允许 0：全透明只剩边框，用户会以为是渲染 bug
      expect(OverlaySettings.opacityLevels.any((v) => v <= 0.0), false);
    });

    test('当前值不在档位上时，取比它大的第一档', () {
      // 模拟从持久化里读到 0.5（旧版本遗留 / 手改）
      const s = OverlaySettings(opacity: 0.5);
      expect(s.withNextOpacity.opacity, 0.6);
    });

    test('当前值超过最大档时回到第一档', () {
      const s = OverlaySettings(opacity: 1.0);
      // 1.0 是最后一档，下一个是 0.25
      expect(s.withNextOpacity.opacity, 0.25);
    });

    test('透明度始终落在允许范围内', () {
      var s = const OverlaySettings();
      for (var i = 0; i < 20; i++) {
        s = s.withNextOpacity;
        expect(s.opacity, greaterThanOrEqualTo(OverlaySettings.minOpacity));
        expect(s.opacity, lessThanOrEqualTo(OverlaySettings.maxOpacity));
      }
    });
  });

  group('SubtitleBgColor 背景预设', () {
    test('每个预设的前景与背景必须有足够对比（防白底白字）', () {
      for (final c in SubtitleBgColor.values) {
        final bgLum = c.background.computeLuminance();
        final fgLum = c.foreground.computeLuminance();
        // 亮度差小于 0.4 的组合在手机上会明显发糊
        expect(
          (bgLum - fgLum).abs(),
          greaterThan(0.4),
          reason: '${c.label} 的前景/背景对比不足',
        );
      }
    });

    test('每个预设的 wire 值唯一且与枚举名解耦', () {
      final wires = SubtitleBgColor.values.map((c) => c.wire).toList();
      expect(wires.toSet().length, wires.length);
      // 锁线上字符串：改名不能悄悄改协议
      expect(SubtitleBgColor.midnight.wire, 'midnight');
      expect(SubtitleBgColor.snow.wire, 'snow');
    });

    test('未知背景色退回默认而不是抛异常', () {
      expect(SubtitleBgColor.fromWire('nonsense'), SubtitleBgColor.midnight);
      expect(SubtitleBgColor.fromWire(null), SubtitleBgColor.midnight);
    });

    test('next 能完整循环一圈', () {
      var c = SubtitleBgColor.midnight;
      final seen = <SubtitleBgColor>[];
      for (var i = 0; i < SubtitleBgColor.values.length; i++) {
        seen.add(c);
        c = c.next;
      }
      expect(c, SubtitleBgColor.midnight, reason: '循环一圈应回到起点');
      expect(seen.length, SubtitleBgColor.values.length);
    });
  });

  group('SubtitlePosition 循环', () {
    test('底部 → 顶部 → 居中 → 底部', () {
      expect(SubtitlePosition.bottom.next, SubtitlePosition.top);
      expect(SubtitlePosition.top.next, SubtitlePosition.center);
      expect(SubtitlePosition.center.next, SubtitlePosition.bottom);
    });

    test('每个位置都映射到插件支持的对齐方式', () {
      // 只允许 topCenter / center / bottomCenter，
      // 避免有人图方便改成 topLeft 把半个屏幕遮住。
      expect(
        SubtitlePosition.values.map((p) => p.alignment.name).toList(),
        ['topCenter', 'center', 'bottomCenter'],
      );
    });

    test('未知的 wire 值退回默认（底部）而不是抛异常', () {
      expect(SubtitlePosition.fromWire('nonsense'), SubtitlePosition.bottom);
      expect(SubtitlePosition.fromWire(null), SubtitlePosition.bottom);
    });
  });

  group('OverlaySettings.fromMap 类型健壮性', () {
    test('整数值的字号（JSON 解出来是 int）不会抛 cast 异常', () {
      // 这是最容易踩的一处：JSONMessageCodec 把 16.0 编码成 16，
      // 解码回来是 int。`as double` 会抛 TypeError。
      final s = OverlaySettings.fromMap(<Object?, Object?>{
        'fontSize': 16,
        'opacity': 1,
        'position': 'top',
      });
      expect(s.fontSize, 16.0);
      expect(s.opacity, 1.0);
      expect(s.position, SubtitlePosition.top);
    });

    test('字段缺失时用默认值', () {
      final s = OverlaySettings.fromMap(<Object?, Object?>{});
      expect(s.fontSize, OverlaySettings.defaultFontSize);
      expect(s.opacity, OverlaySettings.defaultOpacity);
      expect(s.position, SubtitlePosition.bottom);
    });

    test('越界值被 clamp 而不是原样接受', () {
      final s = OverlaySettings.fromMap(<Object?, Object?>{
        'fontSize': 999,
        'opacity': -5,
      });
      expect(s.fontSize, OverlaySettings.maxFontSize);
      expect(s.opacity, OverlaySettings.minOpacity);
    });

    test('toMap → fromMap 往返一致', () {
      const original = OverlaySettings(
        fontSize: 20,
        opacity: 0.8,
        position: SubtitlePosition.center,
        backgroundColor: SubtitleBgColor.snow,
      );
      final round = OverlaySettings.fromMap(original.toMap());
      expect(round, original);
      // 背景色必须真的往返，否则窗口重建后会跳回默认深色
      expect(round.backgroundColor, SubtitleBgColor.snow);
    });
  });

  group('OverlaySettings 相等性', () {
    test('值相同即相等（hashCode 也要一致）', () {
      const a = OverlaySettings(fontSize: 18, opacity: 0.8);
      const b = OverlaySettings(fontSize: 18, opacity: 0.8);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('任一字段不同则不相等', () {
      const base = OverlaySettings();
      expect(base == const OverlaySettings(fontSize: 17), false);
      expect(base == const OverlaySettings(opacity: 0.6), false);
      expect(
        base == const OverlaySettings(position: SubtitlePosition.top),
        false,
      );
    });
  });

  group('命令协议', () {
    test('每个命令的 wire 值唯一（防止复制粘贴写重）', () {
      final wires = OverlayCommand.values.map((c) => c.wire).toList();
      expect(wires.toSet().length, wires.length);
    });

    test('wire 与枚举名解耦（改名不应影响协议）', () {
      // 这里锁的是线上字符串，而不是 Dart 标识符。
      expect(OverlayCommand.stopService.wire, 'stopService');
      expect(OverlayCommand.hideOverlay.wire, 'hideOverlay');
      expect(OverlayCommand.fontIncrease.wire, 'fontIncrease');
      expect(OverlayCommand.fontDecrease.wire, 'fontDecrease');
      expect(OverlayCommand.cycleOpacity.wire, 'cycleOpacity');
      expect(OverlayCommand.cycleBackground.wire, 'cycleBackground');
      expect(OverlayCommand.cyclePosition.wire, 'cyclePosition');
      expect(OverlayCommand.requestSync.wire, 'requestSync');
    });

    test('wire 往返一致', () {
      for (final c in OverlayCommand.values) {
        expect(overlayCommandFromWire(c.wire), c);
      }
    });

    test('未知命令返回 null 而不是抛异常（两端版本可能不一致）', () {
      expect(overlayCommandFromWire('somethingNew'), null);
      expect(overlayCommandFromWire(null), null);
    });

    test('buildCommandMessage 产出可被 readCommand 解析', () {
      for (final c in OverlayCommand.values) {
        final msg = buildCommandMessage(c);
        expect(readCommand(msg), c);
      }
    });

    test('非 command 类型的消息不会被误读成命令', () {
      // 这条很关键：主 App 自己发出的 subtitle 消息会经插件绕一圈
      // 回到自己的 listener 上。若不校验 type，就会把字幕当命令解析，
      // 然后对着 null 命令崩掉或误触发。
      expect(
        readCommand(<Object?, Object?>{
          'type': OverlayMessageType.subtitle,
          'sourceText': 'hello',
          'cmd': 'stopService',
        }),
        null,
        reason: 'type 不是 command 时，即使带了 cmd 字段也不能当命令',
      );
      expect(
        readCommand(<Object?, Object?>{
          'type': OverlayMessageType.settings,
          'fontSize': 16,
        }),
        null,
      );
    });
  });

  group('消息类型常量', () {
    test('四种类型互不相同', () {
      final types = {
        OverlayMessageType.subtitle,
        OverlayMessageType.settings,
        OverlayMessageType.state,
        OverlayMessageType.command,
      };
      expect(types.length, 4);
    });
  });
}