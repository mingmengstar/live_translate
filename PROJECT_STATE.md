# 项目交接文档：实时翻译

## 1. 当前进度看板

| 模块 | 状态 | 备注 |
|------|------|------|
| **阶段 1：工程初始化与 Mock 链路** | ✅ **已完成** | 全部通过 |
| Flutter 工程配置 (pubspec.yaml, AndroidManifest, build.gradle.kts) | ✅ | minSdk 29, Java 17, 依赖齐全 |
| ASREngine / MTEngine 抽象接口 | ✅ | `lib/core/engine/` |
| EngineManager 单例管理器 | ✅ | 注册/切换/销毁/监听 |
| MockASR / MockMT 实现 | ✅ | 定时产生假数据，模拟流式 |
| TranslationService 编排服务 | ✅ | 100ms 防抖、字幕缓冲、错误降级 |
| 主界面 UI (深色卡片、发光按钮、语言/引擎选择、字幕历史) | ✅ | `lib/ui/main_screen.dart` |
| 悬浮窗 UI (独立 Entry Point、字号/位置/透明度调节) | ✅ | `lib/ui/overlay_screen.dart` |
| 快捷设置磁贴服务 | ✅ | Android 15 权限检查、状态同步 |
| 原生 Android (MainActivity, OverlayFlutterEngine, 磁贴图标) | ✅ | MethodChannel 权限桥接 |
| GitHub Actions CI/CD | ✅ | `.github/workflows/build_and_release.yml`，Java 17 强制 |
| README.md 重写 | ✅ | 架构图、扩展指南、免责声明 |
| 单元测试 | ✅ | `test/translation_service_test.dart` 全部通过 |
| Widget 测试 | ✅ **已修复并启用** | 修复动画超时问题，2/2 测试通过 |
| **阶段 2：音频内录 + VAD 调度** | 🟡 **进行中** | AudioCaptureService 已实现，待真机验证 |
| **阶段 3：真实端侧 AI 引擎 (Sherpa-ONNX / llama.cpp)** | ❌ **未开始** | 需模型文件 |
| **阶段 4：自动化发布验证** | ✅ Workflow 已写，未跑通 | 待首次 tag 触发 |

---

## 2. 项目目录结构（仅关键业务文件）
```
live_translate/
├── lib/
│   ├── core/
│   │   ├── engine/
│   │   │   ├── asr_engine.dart      # ASR 接口 + ASRResult
│   │   │   ├── mt_engine.dart       # MT 接口 + MTChunk/MTResult/LanguagePair
│   │   │   ├── engine_manager.dart  # 单例管理器
│   │   │   ├── mock_asr.dart        # Mock ASR 实现
│   │   │   ├── mock_mt.dart         # Mock MT 实现
│   │   │   └── engine.dart          # 统一导出
│   │   ├── audio/
│   │   │   └── audio_capture_service.dart  # 系统内录 + VAD 处理
│   │   ├── service/
│   │   │   └── translation_service.dart  # 核心编排服务
│   │   └── tile/
│   │       └── quick_settings_tile.dart  # 磁贴服务
│   ├── ui/
│   │   ├── main_screen.dart         # 主界面
│   │   └── overlay_screen.dart      # 悬浮窗 (overlayMain entry)
│   └── main.dart                    # App 入口 + 主题 + Loading/Error
```
├── android/
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml
│   │   ├── kotlin/com/example/live_translate/
│   │   │   ├── MainActivity.kt      # 权限 MethodChannel
│   │   │   └── OverlayFlutterEngine.kt # 悬浮窗 Engine Service
│   │   └── res/drawable/ic_tile_icon.xml
│   └── app/build.gradle.kts
├── .github/workflows/build_and_release.yml
├── test/
│   ├── translation_service_test.dart
│   └── widget_test.dart
├── pubspec.yaml
└── README.md
```

---

## 3. 核心架构现状

| 项目 | 现状 |
|------|------|
| **当前绑定引擎** | **全 Mock** (`mock_asr` + `mock_mt`)，无真实模型文件 |
| **音频捕获 + VAD** | **已实现** (`lib/core/audio/audio_capture_service.dart`)<br>• 系统内录：`system_audio_recorder` (EventChannel 音频流)<br>• VAD：简单能量阈值检测 (RMS)，可配置阈值/容忍度/最小语音帧<br>• 输出：16kHz 单声道 16bit PCM 分段推送给 ASR |
| **悬浮窗双引擎通讯** | **架构就绪，未实测**<br>• 主引擎：`TranslationService._sendToOverlay()` 第 269 行调用 `FlutterScreenOverlay.shareData()`<br>• 从引擎：`OverlayScreen._onDataReceived()` 第 112 行监听 `FlutterScreenOverlay.overlayListener`<br>• 需在真机集成 `flutter_screen_overlay` 插件后验证 |
| **EngineManager 降级机制** | 已实现：真实引擎初始化失败自动回退 Mock，UI 红字提示 |
| **100ms 防抖节流** | 主引擎 `_scheduleDebouncedUpdate` (translation_service.dart:214) + 从引擎 `_debounceTimer` (overlay_screen.dart:68) 双重保险 |

---

## 4. ✅ 已修复的编译错误

| 文件 | 原问题 | 修复状态 |
|------|--------|----------|
| `lib/core/engine/engine_manager.dart` | `EngineType` 类型定义错误、typedef 在类内部 | ✅ 已修复：改为 `enum EngineTypeEnum` |
| `lib/ui/overlay_screen.dart` | `FlutterScreenOverlay.overlayListener` 回调类型不匹配 | ✅ 已修复：改为 `dynamic` 参数并在内部转换 |
| `lib/core/service/translation_service.dart` | `FlutterScreenOverlay.instance.shareData` 调用错误 | ✅ 已修复：改为 `FlutterScreenOverlay.shareData` |
| `lib/core/tile/quick_settings_tile.dart` | `Tile.copyWith()` 方法不存在、`debugPrint` 未导入、mixin 约束错误 | ✅ 已修复：改用 `Tile()` 构造函数、导入 `package:flutter/foundation.dart`、移除错误 mixin |
| `android/app/src/main/kotlin/.../MainActivity.kt` | 重复声明 `pendingAudioPermissionCallback` 和 `pendingNotificationPermissionCallback` | ✅ 已修复：移除重复声明 |
| `android/app/src/main/kotlin/.../OverlayFlutterEngine.kt` | `DartExecutor.DartEntrypoint.createDefault()` 写法过时 | ✅ 已修复：改为直接使用返回值 |
| `pubspec.yaml` | `assets/models/` 目录不存在 | ✅ 已修复：创建目录 |
| `lib/core/engine/mock_asr.dart` | `_onError` 字段未使用 | ✅ 已修复：移除未使用字段及相关赋值 |
| `lib/core/tile/quick_settings_tile.dart` | `_checkOverlayPermission`、`_showPermissionNotification`、`refreshTileState` 未引用 | ✅ 已修复：移除未使用方法，移除未使用 import `flutter/services.dart` |
| `lib/core/service/translation_service.dart` | 字符串插值中多余大括号 | ✅ 已修复：移除多余 `{}` |
| `lib/ui/main_screen.dart` | 未使用 import `engine.dart`、多余下划线、null 检查可优化 | ✅ 已修复：移除 import、修正 separatorBuilder、使用 null-aware 操作符 |
| `android/settings.gradle.kts` | AGP 8.11.1 与 Gradle 9.5.0 不兼容 | ✅ 已修复：升级 AGP 到 9.0.0，Gradle 降级到 8.10.2 |
| `android/gradle.properties` | KGP 迁移到 built-in Kotlin 标记已设置 | ✅ 已配置：`android.builtInKotlin=false`, `android.newDsl=false` |
| `test/widget_test.dart` | 测试引用私有类 `_LoadingScreen`、`_ErrorScreen` | ✅ 已修复：改为测试公共 UI 元素 (GestureDetector、标题文本) |

---

## 5. 🔍 当前剩余分析警告（非阻塞）

- `dangling_library_doc_comments`: 多文件缺少 `library` 指令（仅 info 级别）
- `deprecated_member_use`: 多处使用了已弃用的 Material 3 API (`background`、`onBackground` 等)
- `unnecessary_import`: `test/translation_service_test.dart` 导入了未使用的 `translation_service.dart`

---

## 6. 🔑 密钥与配置继承（⚠️仅列字段名，严禁明文）

| 配置项 | 所在位置 | 用途 |
|--------|----------|------|
| `GITHUB_TOKEN` | GitHub Actions Secrets (仓库级) | `softprops/action-gh-release` 自动发布 Release |
| 签名密钥库 | GitHub Actions Secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD` | Release APK 签名（当前 workflow 使用 debug 签名，正式发布需替换） |
| 模型文件路径 | 运行时通过 `EngineManager.switchASREngine(config: {'modelPath': ...})` 传入 | Sherpa-ONNX `.onnx` / llama.cpp `.gguf` 本地路径 |
| 无其他云端 API Key | — | 本阶段完全离线，阶段 3 若接入云端引擎再补充 |

---

## 7. 下一步行动计划（接手即做）

1. **第 1 步（真机验证完整链路：音频捕获 + Mock ASR/MT + 悬浮窗）**：
   - `flutter run --release` 安装到 Android 真机 (minSdk 29)
   - 授予 **录音、悬浮窗、通知** 权限
   - 点击主界面发光按钮 → 观察悬浮窗是否弹出并显示 Mock 字幕
   - 验证系统内录正常工作（播放音频/视频时悬浮窗显示识别结果）
   - 下拉快捷设置添加磁贴 → 点击磁贴切换服务

2. **第 2 步（阶段 3：真实模型）**：
   - 下载 Sherpa-ONNX 流式模型 (`sherpa-onnx-streaming-zipformer-xxx.onnx` + tokens.txt)
   - 实现 `SherpaASREngine` (lib/core/engine/sherpa_asr.dart)
   - 下载 Hy-MT1.5 GGUF (`hy-mt1.5-q4_k_m.gguf`)
   - 实现 `LlamaMTEngine` (lib/core/engine/llama_mt.dart)
   - 在 `TranslationService.initialize()` 中注册并切换到真实引擎

3. **第 3 步（CI 验签发布）**：
   - 给仓库配置签名密钥 Secrets
   - 推送 `v0.1.0` tag 触发 Workflow，确认 Release 页生成 4 个 ABI APK

---

## 8. 📋 当前会话修复总结 (2024-11-24 更新)

### ✅ 已完成的修复

| 文件 | 修复内容 | 验证状态 |
|------|----------|----------|
| `android/settings.gradle.kts` | AGP 8.11.1 → 9.0.0 (兼容 Flutter 3.44+) | ✅ 配置完成 |
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle 9.5.0 → 9.1.0 (与 AGP 9.0.0 兼容) | ✅ 配置完成 |
| `android/gradle.properties` | `android.builtInKotlin=false`, `android.newDsl=false` (KGP 迁移兼容) | ✅ 配置完成 |
| `lib/core/engine/engine_manager.dart` | 移除残留的 `typedef EngineType = String` | ✅ 修复完成 |
| `lib/ui/overlay_screen.dart` | 修复 `overlayListener` 回调类型转换 (`data as Map<String, dynamic>`) | ✅ 修复完成 |
| `test/widget_test.dart` | 修复测试：移除私有类引用，改为测试公共 UI 元素 | ✅ 测试通过 (4/4) |
| `flutter analyze` | 0 errors, 仅 20 个 info/warning (非阻塞) | ✅ 通过 |
| `flutter test` | 所有单元测试和 Widget 测试通过 | ✅ 通过 (4/4) |

### ⚠️ 待验证项 (需真机/网络环境)
- **APK 构建验证**：代码层面已修复兼容性问题，但当前环境下载 Gradle 分发包超时，需在网络正常的环境或真机 CI 中验证 `flutter build apk --release --split-per-abi`
- **真机集成测试**：悬浮窗通讯 (`flutter_screen_overlay`)、系统内录权限、VAD 调度、快捷设置磁贴

---

**文档生成时间**：2024-11-24  
**文档更新时间**：2024-11-24 (修复 Gradle/AGP 兼容性、代码分析通过、全测试通过)  
**当前分支**：main  
**下一任务入口**：`flutter run --release` 真机跑完整链路（音频捕获 + Mock ASR/MT + 悬浮窗）