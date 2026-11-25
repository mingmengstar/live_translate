# HANDOVER.md — live_translate 项目交接文档

## 1. 项目生成时间
**2026-11-25 20:53:11 UTC**

---

## 2. 当前进度看板

### ✅ 已完成
- **架构骨架**：EngineManager 单例、ASREngine/MTEngine 接口、TranslationService 编排、Provider 状态管理
- **Mock 链路全通**：MockASR 定时产生假识别 → TranslationService 100ms 防抖 → MockMT 流式翻译 → 主界面/悬浮窗同步显示
- **音频捕获基础**：system_audio_recorder + 简单能量 VAD（30ms 帧、RMS 阈值 0.02）
- **悬浮窗独立 Engine**：OverlayScreen (`overlayMain` entry-point)、FlutterScreenOverlay 单向数据通道、字号/位置/透明度实时调节
- **快捷设置磁贴**：quick_settings_with_flutter_plugins 绑定系统面板，点击/添加/移除回调完整
- **UI 交互**：深色卡片式、发光按钮动画、实时预览、语言/引擎选择、字幕历史、测试环境兼容
- **CI 配置就绪**：`.github/workflows/build_and_release.yml`（手动安装 Flutter stable、禁用桌面端、Gradle 4G 内存、分 ABI 构建、上传 Artifact、创建 Release）
- **单测通过**：MockASR/MockMT 直接实例化测试，避免单例冲突
- **Gradle/AGP/Kotlin 版本修复**：
  - Gradle wrapper: 8.10.2 → **9.3.1**
  - AGP: 9.0.0 → **9.1.1**
  - Kotlin DSL 迁移到 `kotlin.jvmToolchain(17)`
  - `gradle.properties` 清理废弃标志
- **本地提交已就绪**：`f580a9f` (HEAD → master)

### ❌ 未完成 / 待办
- **CI 推送与验证**：因缺 SSH Key / PAT，尚未推送到 GitHub 触发 Actions
- **WebRTC VAD 替换**：简单能量 VAD 误触发率高，需接入 `flutter_webrtc_vad` 或 JNI 桥接
- **Sherpa-ONNX ASR 接入**：替换 MockASR，离线流式 Zipformer CTC 模型（en/ja/zh/ko）
- **llama.cpp MT 接入**：替换 MockMT，离线 GGUF 量化模型（多语言翻译）
- **模型文件分发策略**：assets 预置 vs 首启动下载（含 SHA256 校验、进度条）
- **双向悬浮窗通道**：目前仅 `shareData()` 单向，需 MethodChannel/EventChannel 反向控制
- **错误恢复/自动重连**：ASR/MT 崩溃、音频流断开、权限撤销后无自动恢复
- **设置持久化**：语言对、引擎选择、悬浮窗参数、模型路径 → SharedPreferences
- **正式 Release v1.0.0**：打 tag、生成 4 架构 APK、更新日志

---

## 3. 项目目录结构（核心业务）

```
lib/
├── core/
│   ├── engine/          # 引擎接口、管理器、Mock 实现
│   │   ├── asr_engine.dart
│   │   ├── mt_engine.dart
│   │   ├── engine_manager.dart
│   │   ├── mock_asr.dart
│   │   └── mock_mt.dart
│   ├── service/         # 业务编排
│   │   └── translation_service.dart
│   ├── audio/           # 音频捕获 + VAD
│   │   └── audio_capture_service.dart
│   └── tile/            # 快捷设置磁贴
│       └── quick_settings_tile.dart
├── ui/
│   ├── main_screen.dart     # 主界面
│   └── overlay_screen.dart  # 悬浮窗界面 (独立 Entry Point)
└── main.dart                # 应用入口

android/
├── app/src/main/kotlin/com/example/live_translate/
│   ├── MainActivity.kt           # 权限 MethodChannel
│   └── OverlayFlutterEngine.kt   # 独立进程 Engine 缓存
├── app/build.gradle.kts          # ✅ 已迁移到 kotlin.jvmToolchain(17)
├── settings.gradle.kts           # ✅ AGP 9.1.1
├── gradle/wrapper/gradle-wrapper.properties  # ✅ Gradle 9.3.1
├── gradle.properties             # ✅ 清理废弃标志
└── src/main/AndroidManifest.xml  # 权限、服务、TileService 声明

.github/workflows/build_and_release.yml  # CI 配置就绪
```

---

## 4. 核心架构现状

| 组件 | 状态 | 说明 |
|------|------|------|
| **ASR 引擎** | MockASR | 定时产生假文本，每 3 秒一条，每 3 条有 1 条 isFinal |
| **MT 引擎** | MockMT | 给文本加语言前缀（如 `【日】`），3 片段流式返回 |
| **EngineManager** | 单例就绪 | 注册工厂、切换/销毁生命周期、状态监听 |
| **TranslationService** | 编排就绪 | 启动 ASR → 推流 → 收结果 → 翻译 → 100ms 防抖 → 字幕缓冲 + Overlay 推送 |
| **AudioCaptureService** | 基础可用 | system_audio_recorder + 简单能量 VAD，**误触发严重**，需换 WebRTC VAD |
| **OverlayScreen** | 独立 Engine 运行 | `overlayMain()` @pragma('vm:entry-point')，FlutterScreenOverlay 单向接收 |
| **QuickSettingsTile** | 系统集成就绪 | 点击切换服务状态，同步 Tile 图标/副标题 |

---

## 5. 🚨 遗留报错与待修复项

| 优先级 | 问题 | 位置/现象 | 建议修复 |
|--------|------|-----------|----------|
| **P0** | **简单能量 VAD 误触发/漏触发严重** | `lib/core/audio/audio_capture_service.dart:_processAudioFrame` (L204-263) | 引入 WebRTC VAD (`flutter_webrtc_vad` 或 JNI `org.webrtc:webrtc`) |
| **P0** | **CI 未真正跑通** | 需推送 tag 或 workflow_dispatch 触发 | 推送 PAT/SSH 后 `git push origin master`，再打 tag `v0.1.0-ci-test` |
| **P1** | **Sherpa-ONNX / llama.cpp 真实模型未接入** | `pubspec.yaml` 已声明依赖但无实现类 | 新建 `sherpa_asr.dart`、`llama_mt.dart` 实现接口并注册 |
| **P1** | **模型文件分发策略未定** | APK 体积、首启动下载、版本管理 | 设计 ModelLoader + 下载/校验/缓存机制 |
| **P2** | **悬浮窗仅单向数据通道** | `TranslationService._sendToOverlay()` 仅 `FlutterScreenOverlay.shareData()` | 增加 MethodChannel 反向控制（如悬浮窗点击停止） |
| **P3** | **语言代码硬编码分散** | `en/ja/zh/ko` 分布在多文件 | 抽取 `LanguageRegistry` 统一管理 |
| **P3** | **无错误恢复/自动重试** | ASR/MT 崩溃、音频流断开、权限撤销 | TranslationService 增加健康检查 + 自动重连 |

---

## 6. 🔑 密钥与配置继承（安全脱敏）

| 配置项 | 用途 | 状态 |
|--------|------|------|
| **GITHUB_TOKEN / PAT** | GitHub Actions 推送、创建 Release、上传 Artifact | **需配置**（Settings → Secrets → Actions） |
| **Signing Keystore** | Release APK 签名（当前用 debug 密钥） | **需配置**生产密钥（`keystore.jks`、`keyAlias`、`storePassword`、`keyPassword`） |
| **模型下载 URL / SHA256** | Sherpa/llama 模型分发（GitHub Release 或 CDN） | **需配置** |
| **Flutter SDK 渠道** | CI 中 `flutter channel stable` | 当前 workflow 已写死 `stable` |

> **安全红线**：**绝对严禁输出密钥明文**。上述仅列出字段名，明文由您本人线下保管并填入 GitHub Secrets。

---

## 7. ⚠️ 钢印级开发约束

1. **云端构建红线**：**必须在 GitHub Actions 构建**，严禁本地执行 `flutter build apk` / `gradlew`。所有编译、打包、发 Release 仅在 CI 完成。
2. **防崩红线**：
   - 推理（ASR/MT）必须在 **Isolate** 执行，避免阻塞 UI 线程。
   - 悬浮窗更新必须做 **100ms 防抖/节流**（已在 `TranslationService._scheduleDebouncedUpdate` 与 `OverlayScreen._debounceTimer` 双重保险）。
3. **资源释放**：切引擎/关服务必须 `dispose()` 所有资源（EngineManager.disposeAll、AudioCaptureService.dispose、OverlayFlutterEngine 销毁 Engine）。
4. **版本锁定**：Gradle 9.3.1 / AGP 9.1.1 / Kotlin 2.2.20 / Flutter 3.50+ / Dart 3.14+ —— 禁止随意升降级。
5. **Mock 先行**：新增引擎必须同时提供 Mock 实现，便于 CI 无模型跑通全链路。

---

## 8. 下一步行动计划（接手后按序执行）

| 步骤 | 动作 | 产出 |
|------|------|------|
| **1** | **配置 GitHub PAT/SSH 并推送** | `git push origin master` → 触发 CI 验证 Gradle/AGP 修复 |
| **2** | **打 CI 验收 tag** | `git tag v0.1.0-ci-test && git push origin v0.1.0-ci-test` → Actions 绿构建、产出 4 架构 APK |
| **3** | **下载 Artifact 真机验证** | 安装 APK，跑通 Mock 链路，确认悬浮窗/磁贴/权限正常 |
| **4** | **接入 WebRTC VAD** | 替换 `AudioCaptureService._processAudioFrame` 能量判断为 `WebRtcVad.Process()` |
| **5** | **实现 SherpaASR** | `lib/core/engine/sherpa_asr.dart` + 注册 + 模型加载器（assets 或下载） |
| **6** | **实现 LlamaMT** | `lib/core/engine/llama_mt.dart` + 注册 + 模型加载器 |
| **7** | **双向悬浮窗通道** | MethodChannel 反向控制（停止/语言切换/字号） |
| **8** | **错误恢复/持久化/设置页** | 健康检查、SharedPreferences、UI 设置持久化 |
| **9** | **正式 Release v1.0.0** | 打 tag `v1.0.0`，GitHub Release 自动生成 APK + 更新日志 |

---

> **交接人提示**：当前 HEAD `f580a9f` 已包含 Gradle/AGP/Kotlin 版本修复，**首要任务是配置 PAT 推送触发 CI**，切勿在本地再次构建。