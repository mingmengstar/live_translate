/// 翻译原生库防回归测试
///
/// ## 为什么需要这组测试
///
/// P0-4（`libmtmd.so` 缺失）之所以拖了很久，是因为它在 **CI 上永远成功**：
/// 构建能过、APK 能出、单测全绿，只有真机运行到 `initialize()` 才炸。
/// 也就是说「构建通过」完全不能证明「翻译能用」。
///
/// 这组测试把判断依据从「构建是否成功」换成「依赖里到底有没有 Android
/// 动态库」，在 `flutter test` 阶段就把问题暴露出来，不需要真机，
/// 也不需要下载 1GB 权重。
///
/// 具体校验三件事：
/// 1. `llama_cpp_dart` 固定在带 AAR 的版本上（防止有人手滑降回 0.2.2）；
/// 2. 该包自带的 AAR 真的存在，且内含 `libmtmd.so` + `libllama.so`；
/// 3. `hook/build.dart`（native assets 入口）存在 —— 没有它，AAR 不会被
///    Flutter 解包，APK 里照样没 `.so`。
library live_translate.test.native_bundle_test;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 带 Android 预编译产物的最低版本
///
/// 0.2.x 全系没有 Android `.so`；0.9.x 起改走 native assets 钩子并自带 AAR。
const String kMinLlamaCppVersion = '0.9.0';

/// 通过 `.dart_tool/package_config.json` 找到某个依赖在磁盘上的实际根目录
///
/// 不硬编码 `~/.pub-cache`，因为 CI / 本地 / 国内镜像（pub.flutter-io.cn）
/// 的缓存路径都不一样。
Directory? _packageRoot(String packageName) {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) return null;

  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, Object?>) return null;

  final packages = decoded['packages'];
  if (packages is! List) return null;

  for (final entry in packages) {
    if (entry is! Map) continue;
    if (entry['name'] != packageName) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) return null;

    // rootUri 可能是绝对 file:// 也可能是相对项目根的 ../ 路径
    final asUri = Uri.parse(rootUri);
    if (asUri.isScheme('file')) {
      return Directory.fromUri(asUri);
    }
    final projectRoot = Directory.current.uri;
    return Directory.fromUri(projectRoot.resolveUri(asUri));
  }
  return null;
}

/// 读 pubspec.lock 里某个包的锁定版本
String? _lockedVersion(String packageName) {
  final lock = File('pubspec.lock');
  if (!lock.existsSync()) return null;

  final lines = lock.readAsLinesSync();
  var inPackage = false;
  for (final line in lines) {
    // 顶层包名行形如 `  llama_cpp_dart:`（两个空格缩进）
    if (RegExp(r'^  [A-Za-z0-9_]+:$').hasMatch(line)) {
      inPackage = line.trim() == '$packageName:';
      continue;
    }
    if (!inPackage) continue;
    final match = RegExp(r'^    version: "([^"]+)"$').firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// 把版本字符串切成可比较的数字段（忽略 -dev / +build 后缀）
List<int> _versionParts(String version) {
  final core = version.split('-').first.split('+').first;
  return core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
}

bool _versionAtLeast(String actual, String minimum) {
  final a = _versionParts(actual);
  final b = _versionParts(minimum);
  final len = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) return av > bv;
  }
  return true;
}

void main() {
  group('llama_cpp_dart Android 原生库', () {
    test('锁定版本必须 >= $kMinLlamaCppVersion（否则没有 Android .so）', () {
      final version = _lockedVersion('llama_cpp_dart');
      expect(
        version,
        isNotNull,
        reason: 'pubspec.lock 里找不到 llama_cpp_dart，先跑 flutter pub get',
      );

      expect(
        _versionAtLeast(version!, kMinLlamaCppVersion),
        isTrue,
        reason: '锁在 $version，该版本不含 Android 动态库；'
            '0.2.x 全系会让 LlamaMTEngine 在真机上必然降级 Mock（P0-4）。',
      );
    });

    test('包根目录可定位（package_config.json 正常）', () {
      final root = _packageRoot('llama_cpp_dart');
      expect(
        root,
        isNotNull,
        reason: '读不到 .dart_tool/package_config.json 里的 llama_cpp_dart 条目',
      );
      expect(root!.existsSync(), isTrue);
    });

    test('自带 AAR 存在且内含 libllama.so + libmtmd.so', () {
      final root = _packageRoot('llama_cpp_dart');
      if (root == null) {
        fail('无法定位 llama_cpp_dart 包目录');
      }

      final aar = File(
        '${root.path}${Platform.pathSeparator}native'
        '${Platform.pathSeparator}android'
        '${Platform.pathSeparator}llama-cpp-dart.aar',
      );

      expect(
        aar.existsSync(),
        isTrue,
        reason: '${aar.path} 不存在。没有这个 AAR，native assets 钩子就无从'
            '解包，APK 里不会有 libmtmd.so。',
      );

      // AAR 是 zip：直接按字节找两个库的条目名，不引入额外依赖。
      // 条目名会以明文出现在 zip 的 central directory 里。
      final bytes = aar.readAsBytesSync();
      final asLatin1 = latin1.decode(bytes, allowInvalid: true);

      expect(
        asLatin1.contains('libllama.so'),
        isTrue,
        reason: 'AAR 里没有 libllama.so，翻译引擎无法启动',
      );
      expect(
        asLatin1.contains('libmtmd.so'),
        isTrue,
        reason: 'AAR 里没有 libmtmd.so —— 正是历史上导致 P0-4 的那个库',
      );
    });

    test('存在 native assets 构建钩子 hook/build.dart', () {
      final root = _packageRoot('llama_cpp_dart');
      if (root == null) {
        fail('无法定位 llama_cpp_dart 包目录');
      }

      final hook = File(
        '${root.path}${Platform.pathSeparator}hook'
        '${Platform.pathSeparator}build.dart',
      );

      expect(
        hook.existsSync(),
        isTrue,
        reason: '没有 hook/build.dart，Flutter 不会把 AAR 解成 code asset，'
            '即使 pubspec 依赖了带 .so 的版本也没用。',
      );

      final content = hook.readAsStringSync();
      expect(
        content.contains('buildCodeAssets'),
        isTrue,
        reason: '钩子没有检查 buildCodeAssets，可能不会真正产出 code asset',
      );
      // ABI → 目录名的映射与 AAR 解包逻辑在包的 lib/ 里，由钩子 import 进来。
      // 这里只确认钩子确实调用了它（否则 AAR 存在也不会被解包）。
      expect(
        content.contains('extractAndroidLibraries'),
        isTrue,
        reason: '钩子没有调用 AAR 解包逻辑，native 库不会被产出',
      );

      final helper = File(
        '${root.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}src${Platform.pathSeparator}hook'
        '${Platform.pathSeparator}android_native_assets.dart',
      );
      expect(
        helper.existsSync(),
        isTrue,
        reason: '缺少 ABI/解包实现，钩子即使调用也跑不起来',
      );
      expect(
        helper.readAsStringSync().contains('arm64-v8a'),
        isTrue,
        reason: '解包实现里应出现 arm64-v8a 的 ABI 映射',
      );
    });
  });

  group('本项目的 pubspec 约束', () {
    test('pubspec.yaml 未把 llama_cpp_dart 降回 0.2.x', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);

      final content = pubspec.readAsStringSync();
      expect(
        content.contains('llama_cpp_dart: 0.9.0-dev.12'),
        isTrue,
        reason: 'pubspec.yaml 里的 llama_cpp_dart 版本被改动了。'
            '若要升级，请同步确认新版本仍自带 Android AAR + hook/build.dart。',
      );
    });

    test('llama_mt.dart 不再使用 0.2.x 的旧 API', () {
      final source = File(
        'lib${Platform.pathSeparator}core'
        '${Platform.pathSeparator}engine'
        '${Platform.pathSeparator}llama_mt.dart',
      );
      expect(source.existsSync(), isTrue);

      final content = source.readAsStringSync();
      // 这些名字在 0.9.x 里已经不存在，残留即说明迁移没做完
      for (final removed in <String>[
        'LlamaParent',
        'sendPrompt',
        'LlamaLoad(',
        'LlamaFlashAttnType',
      ]) {
        expect(
          content.contains(removed),
          isFalse,
          reason: 'llama_mt.dart 仍引用 0.2.x 的 `$removed`，'
              '在 0.9.x 上无法编译/行为不符',
        );
      }

      // 新 API 必须真的被用上
      expect(content.contains('LlamaEngine.spawn'), isTrue);
      expect(content.contains('createSession'), isTrue);
    });
  });
}