# HANDOVER.md — live_translate 项目交接文档

## 1. 项目生成时间（真实系统时间）

**2026-11-26 00:29:39 UTC（Thursday）｜2026-11-26 08:29:39 CST**

- 取自容器内 `date -u` 与 `TZ=Asia/Shanghai date` 的真实输出，非模型记忆时间。
- 仓库：`https://github.com/mingmengstar/live_translate.git`
- 当前 HEAD：`66ff7e9`（master），上一个 CI 验收 tag：`v0.1.0-ci-test-4` → `f6b7fdf`
- 工作区存在**未提交改动**（详见第 9 节），本次 VAD 重构尚未 commit / push。

---

## 2. 当前进度看板

### ✅ 已完成

- **架构骨架**：`EngineManager` 单例、`ASREngine` / `MTEngine` 抽象接口、`TranslationService` 编排、Provider 状态管理。
- **Mock 链路全通**：MockASR（3s 一条，每 3 条 1 条 `isFinal`）→ 100ms 防抖 → MockMT（3 段流式）→ 主界面 + 悬浮窗同步显示。
- **Android 原生层**：`MainActivity` 权限 MethodChannel、`OverlayFlutterEngine`（独立进程 `:overlay`、`executeDartEntrypoint`）、快捷设置磁贴。
- **CI 已实现绿构建（重大结论修正）**：
  - Run #22（tag `v0.1.0-ci-test-4`，commit `f6b7fdf`）**conclusion = success**，21 个 step 全绿。
  - Artifact `release-apks` 真实产出，约 **106 MB**（非空）。
  - Release 页已生成 3 个 APK：`app-arm64-v8a` / `app-armeabi-v7a` / `app-x86_64`。
  - → 旧文档所述「卡在 `checkReleaseAarMetadata`」**已解决**：`android/build.gradle.kts` 的反射式 `setCompileSdk(36)` 覆盖生效。
- **模型分发通道已就绪**：GitHub Release `v1.0.0-models` 已托管 `encoder.onnx` / `decoder.onnx` / `joiner.onnx` / `tokens.txt` / `silero_vad.onnx` / `hy-mt1.5-q4_k_m.gguf`。
- **VAD 重构（本轮新增，已完成编码 + 全测试通过）**：
  - 新增 `lib/core/audio/vad/` 六个文件：类型层、自适应能量检测器、分段状态机、Silero 后端、isolate worker、主 isolate host。
  - **所有 VAD 推理移入独立 Isolate**（`vad_isolate_worker.dart`），主线程零计算，符合防崩红线。
  - **Silero VAD 优先**（复用已声明的 `sherpa_onnx 2.0.3`，**未新增任何插件**，不动 AAR metadata 雷区）；模型缺失/加载失败自动降级能量 VAD。
  - **修复真实 bug**：旧能量 VAD 的 `frame[i] | (frame[i+1] << 8)` 缺少 int16 符号扩展，负样本被当正值，RMS 虚高数量级 → 这是「误触发严重」的真实根因之一。
  - 能量 VAD 新增自适应噪声底 + 滞回（hysteresis），嘈杂/安静环境共用同一组参数。
  - 分段器新增前导静音回补（90ms）、尾部静音裁剪、强制切分保留 2 帧重叠、`flush()` 吐出末段。
  - `test/vad_test.dart` 新增 13 个用例；`flutter test` 全量 **18/18 passed**；`dart analyze lib` 仅 3 条既有 info（0 error / 0 warning）。

### ❌ 未完成 / 待办

| 项目 | 状态 | 备注 |
|------|------|------|
| Sherpa-ONNX ASR 接入 | ❌ 未开始 | `pubspec.yaml` 已声明 `sherpa_onnx ^2.0.3`，但**无实现类**；无 `sherpa_asr.dart` |
| llama.cpp MT 接入 | ❌ 未开始 | 已声明 `llama_cpp_dart ^0.2.2`，无 `llama_mt.dart` |
| 模型下载/校验管线 | ❌ 未设计 | `assets/models/` 目前**只有 `.gitkeep`**；必须走运行时下载 + SHA256 + 进度条 |
| 双向悬浮窗通道 | ❌ 仅单向 | `FlutterScreenOverlay.shareData()` 单向；`OverlayFlutterEngine` 的 MethodChannel handler 全是占位 `result.success(true)` |
| 设置持久化 | ❌ 无 | 已声明 `shared_preferences` 但未落地；字号/位置/语言重启即丢 |
| 错误恢复 / 自动重连 | ❌ 无 | 无健康检查、无断流重试 |
| Release 签名 | ❌ 仍用 debug 签名 | `android/app/build.gradle.kts:34` → `signingConfigs.getByName("debug")` |
| Built-in Kotlin 迁移 | ⚠️ 技术债 | `android.builtInKotlin=false` / `android.newDsl=false`，AGP 10 将移除 |
| Release 文案与产物不符 | ⚠️ 待修 | Workflow 用 `--split-per-abi`，只产 3 个 ABI APK，但 Release 描述里宣称存在通用包 `app-release.apk` |
| 正式 v1.0.0 发布 | ❌ 未发布 | 需先配签名 Secrets |

---

## 3. 项目目录结构（核心业务，极简）

```
live_translate/
├── HANDOVER.md / PROJECT_STATE.md / pubspec.yaml
├── lib/
│   ├── main.dart                          # App 入口 + 主题 + Loading/Error
│   ├── core/
│   │   ├── engine/
│   │   │   ├── asr_engine.dart            # ASREngine + ASRResult
│   │   │   ├── mt_engine.dart             # MTEngine + MTChunk/MTResult/LanguagePair
│   │   │   ├── engine_manager.dart        # 单例注册/切换/销毁
│   │   │   ├── mock_asr.dart              # Mock ASR
│   │   │   ├── mock_mt.dart               # Mock MT
│   │   │   └── engine.dart                # 统一导出
│   │   ├── audio/
│   │   │   ├── audio_capture_service.dart # 系统内录 → VAD → 语音段回调（已重构）
│   │   │   └── vad/                       # ★本轮新增
│   │   │       ├── vad_types.dart          # VadConfig / VadState / VadSegment / 后端枚举
│   │   │       ├── vad_detector.dart       # VadDetector 接口 + 自适应能量 VAD + PCM 解码
│   │   │       ├── vad_segmenter.dart      # 分段状态机（前导回补/尾部裁剪/重叠切分）
│   │   │       ├── silero_vad_backend.dart # Silero VAD（sherpa_onnx）+ Float32↔PCM16
│   │   │       ├── vad_isolate_worker.dart # isolate worker（vm:entry-point）
│   │   │       └── vad_service.dart        # 主 isolate host（启动/投递/flush/dispose）
│   │   ├── service/translation_service.dart # 编排 + 100ms 防抖 + 悬浮窗推送
│   │   └── tile/quick_settings_tile.dart    # 磁贴回调
│   └── ui/
│       ├── main_screen.dart               # 主界面（826 行）
│       └── overlay_screen.dart            # 悬浮窗 overlayMain entry-point（565 行）
├── android/
│   ├── build.gradle.kts                   # ★compileSdk=36 反射覆盖（CI 绿的关键）
│   ├── settings.gradle.kts                # AGP 9.3.1 / Kotlin 2.4.20
│   ├── gradle.properties                  # builtInKotlin=false / newDsl=false
│   ├── gradle/wrapper/gradle-wrapper.properties  # Gradle 9.5.0
│   └── app/.../kotlin/com/example/live_translate/
│       ├── MainActivity.kt                # 权限 MethodChannel
│       └── OverlayFlutterEngine.kt        # 独立进程 Engine
├── test/
│   ├── vad_test.dart                      # ★本轮新增，13 个 VAD 用例
│   ├── translation_service_test.dart      # MockASR/MockMT
│   └── widget_test.dart                   # 主界面渲染
└── .github/workflows/build_and_release.yml # 唯一允许的构建入口
```

---

## 4. 核心架构现状

| 组件 | 现状 | 说明 |
|------|------|------|
| ASR 引擎 | **Mock** | 定时产假文本，无真实推理 |
| MT 引擎 | **Mock** | 加语言前缀（`【日】`），3 段流式 |
| EngineManager | 单例就绪 | 注册/切换/销毁 + 降级回 Mock |
| TranslationService | 编排就绪 | ASR → MT → 100ms 防抖 → 字幕缓冲 + Overlay 推送 |
| AudioCaptureService | ✅ 已重构 | `system_audio_recorder` → **VAD Isolate** → `VadSegment` |
| VAD | ✅ Silero 优先 + 能量兜底 | 全部 isolate 执行；能量 VAD 已修符号扩展 bug |
| OverlayScreen | 独立 Engine | `overlayMain()` + `@pragma('vm:entry-point')` |
| 悬浮窗通讯 | ⚠️ **单向** | 主 Engine → `shareData()` → Overlay。**反向控制未实现** |

> **结论：全链路仍绑定 Mock，无任何真实推理引擎。悬浮窗通讯为单向。**

---

## 5. 🚨 遗留报错与待修复项

### P0-1｜CI 已绿，但 Release 文案与产物不符（非阻塞，需修正）

- 位置：`.github/workflows/build_and_release.yml` 第 238–255 行。
- 现象：构建用 `flutter build apk --release --split-per-abi`，只产 `app-arm64-v8a-release.apk`、`app-armeabi-v7a-release.apk`、`app-x86_64-release.apk`；Release 描述却宣称有通用包 `app-release.apk`，`files:` 里也列了不存在的该文件。
- 建议：要么去掉描述与 files 中的 `app-release.apk`，要么额外构建一次通用 APK。

### P0-2｜真实引擎缺失（业务阻塞）

- `lib/core/engine/` 下无 `sherpa_asr.dart`、无 `llama_mt.dart`。
- `pubspec.lock` 实锁版本：`sherpa_onnx 2.0.3`、`llama_cpp_dart 0.2.2`（旧文档写的 `1.13.8 / 0.9.0-dev.12` 已过期）。
- `assets/models/` 仅 `.gitkeep`，**模型不在 APK 内**，必须运行时下载。

### P1｜悬浮窗双向通道未实现

- `translation_service.dart:287 _sendToOverlay()` 仅 `shareData()`。
- `OverlayFlutterEngine.kt` 的 MethodChannel handler 全为占位 `result.success(true)`，停止/切语言/调字号均无法回传主引擎。

### P1｜设置无持久化

- 悬浮窗字号/位置/透明度、语言对、引擎选择全部内存态，重启丢失。`overlay_screen.dart:144` 注释已标注 `// 实际项目中应持久化到 SharedPreferences`。

### P2｜无错误恢复 / 健康检查

- 音频流 `onError` 仅打日志（`audio_capture_service.dart` 第 141 行附近），无重连；`TranslationService` 无引擎健康检查。

### P2｜Release 使用 debug 签名

- `android/app/build.gradle.kts:34` → `signingConfig = signingConfigs.getByName("debug")`。

### P3｜Built-in Kotlin 技术债

- `android/gradle.properties`：`android.builtInKotlin=false`、`android.newDsl=false`。AGP 9.3 仍支持，**AGP 10.0 将移除**。涉及插件：`flutter_foreground_task`、`quick_settings_with_flutter_plugins`、`system_audio_recorder`。

### P3｜语言代码硬编码分散

- `en / ja / zh / ko` 散落于 `mock_asr.dart`、`mock_mt.dart`、`translation_service.dart`、`main_screen.dart`，缺 `LanguageRegistry`。

### 已修复（勿重复排查）

| 曾报错 | 修复方式 | 验证 |
|--------|---------|------|
| `flutter.jar` 不存在（`android-arm/flutter.jar`） | CI 新增 `flutter precache --android --no-ios` + 残缺缓存 `rm -rf` + 硬校验 | ✅ step success |
| `Invalid format '...'`（GITHUB_OUTPUT 多行） | 改 heredoc `body<<RELEASE_BODY_EOF` | ✅ |
| `OverlayFlutterEngine.kt` 无 `runAppWithEntrypoint` | 改 `executeDartEntrypoint()` | ✅ 0 Kotlin 错误 |
| `checkReleaseAarMetadata` 15 项（插件 compileSdk=33 < 依赖要求 34） | `android/build.gradle.kts` 反射 override `setCompileSdk(36)` | ✅ Run #22 全绿 |
| 能量 VAD 负样本错判（RMS 虚高 → 误触发） | `pcm16ToFloat32()` 正确 int16 符号扩展 + 自适应底噪 + 滞回 | ✅ `vad_test.dart` 回归用例 |
| 分段器误计静音帧为语音帧 | `speaking` 分支仅 `isSpeech` 才自增 `_speechFrameCount` | ✅ `vad_test.dart` |
| widget 测试 `timersPending` 断言失败 | `VadService._teardown()` 仅在 worker 存在时 `delay` | ✅ 18/18 passed |

---

## 6. 🔑 密钥与配置继承（安全脱敏）

> **安全红线：本节仅列字段名。绝对禁止写入、索取或输出任何明文。明文由项目所有者线下保管。**

| 字段名 | 用途 | 状态 |
|--------|------|------|
| `GITHUB_TOKEN`（或 PAT，需 `repo` + `workflow` scope） | Actions 建 Release、上传 Artifact | 工作流已引用 `${{ secrets.GITHUB_TOKEN }}`，**仓库级自动可用** |
| `KEYSTORE_BASE64` | Release 签名 `keystore.jks` 的 base64 | **需配置**（线下保管原始文件） |
| `KEY_ALIAS` | 签名 key 别名 | **需配置** |
| `STORE_PASSWORD` | keystore 密码 | **需配置** |
| `KEY_PASSWORD` | key 密码 | **需配置** |
| 模型下载 URL | Sherpa / llama 模型分发地址 | 已确定通道（Release `v1.0.0-models`） |
| 模型 SHA256 | 模型完整性校验值 | **需配置**，仅在代码中以占位常量引用 |

> ⚠️ 历史事件：2026-11-25 曾有 PAT 在聊天中明文粘贴，**视为已泄露，必须吊销重建**（https://github.com/settings/tokens）。
> 下一个 Agent：**不得索取、不得输出任何凭据明文**，也不得把密钥写进仓库任何文件。

---

## 7. ⚠️ 钢印级开发约束（不可违反）

1. **云端构建红线**：**必须且只能在 GitHub Actions 构建**。严禁在本地 / 对话环境执行 `flutter build apk`、`flutter build appbundle`、`gradlew`、`./gradlew assemble*` 等任何编译打包命令。本地**只允许**静态代码阅读、文本编辑、`dart analyze`、`flutter test`（不产 APK）。所有编译、打包、发 Release 仅在 CI 完成。
2. **防崩红线**：
   - ASR / MT / VAD 推理必须在 **Isolate** 执行，严禁阻塞 UI 线程（VAD 已达标，见 `vad_isolate_worker.dart`）。
   - 悬浮窗更新必须做 **100ms 防抖/节流**：`TranslationService._scheduleDebouncedUpdate` + `OverlayScreen._debounceTimer` 双重保险，**勿移除**。
3. **资源释放**：切引擎 / 关服务必须 `dispose()` 全部资源 —— `EngineManager.disposeAll`、`AudioCaptureService.dispose`（内含 `VadService.dispose`）、`OverlayFlutterEngine` 销毁 Engine 并从 `FlutterEngineCache` 移除。
4. **版本锁定**：Gradle **9.5.0** / AGP **9.3.1** / Kotlin **2.4.20** / Flutter ≥ 3.47 / Dart ≥ 3.13 —— 禁止随意升降级。
5. **Mock 先行**：新增引擎必须同时提供 Mock 实现，保证 CI 无模型可跑通全链路。
6. **CI 诊断纪律**：
   - 严禁给构建步骤加 `continue-on-error: true`（会掩盖失败）。
   - CI 报错先抓完整日志（`GET /actions/runs/{id}/logs`）通读再改，**禁止盲改连推**。
   - 每次修复只推一个焦点改动，避免多层错误混杂。

---

## 8. 下一步行动计划

### 第 1 步（接手第一件事）：把本轮 VAD 重构提交并推送，让 CI 验证

本轮已改完但**尚未 commit / push**。先本地确认（**只允许 analyze + test，不得 build**）：

```bash
cd <workspace>
dart analyze lib          # 期望：0 error / 0 warning，仅 3 条既有 info
flutter test              # 期望：18/18 passed
git add lib/core/audio/vad lib/core/audio/audio_capture_service.dart test/vad_test.dart HANDOVER.md
git commit -m "feat(audio): isolate-based VAD with Silero backend + energy fallback"
git push origin master
git tag v0.2.0-ci-test-5
git push origin v0.2.0-ci-test-5
```

然后在 GitHub Actions 页面跟踪 Run，**不得本地构建**。

### 第 2 步：修 Release 文案与产物不符（P0-1）

改 `.github/workflows/build_and_release.yml`：删除 `app-release.apk` 的描述行与 `files:` 条目，只保留 3 个分 ABI 产物。

### 第 3 步：实现 `SherpaASREngine`（P0-2 前半）

- 新建 `lib/core/engine/sherpa_asr.dart`，实现 `ASREngine` 接口。
- 参考 pub 缓存实测 API：`OnlineRecognizer.fromTransducer(...)`、`recognizer.createStream()`、`stream.acceptWaveform(samples: Float32List, sampleRate:)`、`recognizer.isReady(stream)` → `recognizer.decode(stream)` → `recognizer.getResult(stream)`、`recognizer.isEndpoint(stream)`。
- **推理必须在 isolate**：`sherpa_onnx` 的 FFI 绑定是 per-isolate，worker 内必须自行 `initBindings()`。
- 同时提供 `MockASR` 路径不变，保证 CI 无模型可跑通。

### 第 4 步：实现模型下载 + 校验管线

- 新建 `lib/core/model/model_loader.dart`：下载 `v1.0.0-models` 内文件到 `path_provider` 目录、SHA256 校验、进度回调、断点/重试。
- 首启动检测缺模型 → 引导页；**不得把模型打进 APK**（当前 workflow 已 `rm -rf` 模型目录）。

### 第 5 步：实现 `LlamaMTEngine`

- 新建 `lib/core/engine/llama_mt.dart`，基于 `llama_cpp_dart 0.2.2`（实测 API：`LlamaParent` + `isolate_child`，流式用 `completions` Stream）。
- 同样 isolate 执行 + Mock 兜底。

### 第 6 步：双向悬浮窗通道

- `OverlayFlutterEngine.kt` 的 MethodChannel handler 落地（停止/切语言/调字号/调透明度）。
- Overlay 侧用 `MethodChannel` 主动 invoke 回传主引擎。

### 第 7 步：设置持久化 + 错误恢复

- 用已声明的 `shared_preferences` 持久化字号/位置/透明度/语言对/引擎选择。
- `TranslationService` 增加健康检查与断流重连。

### 第 8 步：正式 Release v1.0.0

- 配置 4 个签名 Secrets → 切换 `signingConfig` → 推 tag。

---

## 9. 工作区未提交改动（接手指南）

当前 `git status`：

```
 M .github/workflows/build_and_release.yml   # 本地删掉了两个诊断 step，远端仍有 → 需决定保留哪个
 M HANDOVER.md                               # 本次重写
 M lib/core/audio/audio_capture_service.dart # 本轮重构
?? lib/core/audio/vad/                       # 本轮新增 6 个文件
?? test/vad_test.dart                        # 本轮新增
```

> 注意：`android/build.gradle.kts` 曾出现 `D`（被删）状态，已从 `f6b7fdf` 原样恢复，当前与 HEAD 一致。
> `PROJECT_STATE.md` 曾出现 `D`，已 `git checkout` 恢复。

---

> **交接人最后提示**：截至 **2026-11-26 00:29:39 UTC**，CI 最近一次成功运行为 Run #22（`f6b7fdf`，tag `v0.1.0-ci-test-4`），已产出 106MB artifact 与 3 个 ABI APK。**当前无编译阻塞**；唯一真正的功能缺口是「真实 ASR/MT 引擎 + 模型分发 + 悬浮窗双向通道」。请从第 8 节第 1 步开始，**切勿本地构建，切勿索取密钥明文**。