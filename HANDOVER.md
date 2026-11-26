# HANDOVER.md — live_translate 项目交接文档

## 1. 项目生成时间（真实系统时间）

**2026-11-26 02:39:27 UTC（Thursday）｜2026-11-26 10:39:27 CST**

- 取自容器内 `date -u` 与 `TZ=Asia/Shanghai date` 的真实输出，非模型记忆时间。
- 仓库：`https://github.com/mingmengstar/live_translate.git`
- 当前 HEAD：`f58760e`（master），最新 CI 验收 tag：`v0.2.1-ci-test-6` → `f58760e`
- **本轮新增未提交改动**：首页 + 模型导入页（P0-1 已落地），详见第 10 节。

---

## 2. 当前进度看板

### ✅ 已完成

- **架构骨架**：`EngineManager` 单例、`ASREngine` / `MTEngine` 抽象接口、`TranslationService` 编排、Provider 状态管理。
- **P0-1 首页 + 模型导入页（本轮新完成）**：
  - `lib/ui/home_screen.dart`：作为 `main.dart` 的 home；含品牌头、服务状态主视觉卡、**模型状态卡**（真实检测）、引擎状态卡（Mock/真实标识）、「进入翻译控制台」「模型管理与导入」双入口、下拉刷新。
  - `lib/ui/model_import_screen.dart`：真实扫描模型目录、逐文件「已就绪/缺失」清单、目录路径一键复制、ADB 手动放置说明；**不做假进度条**。
  - `lib/core/model/model_storage.dart`：统一模型目录（`getApplicationSupportDirectory()/models`）+ 6 个必需文件规格 + `inspect()` 就绪判定（ASR+MT 齐全即就绪，VAD 可选）。
  - `lib/ui/main_screen.dart`：仅新增「返回」按钮（`Navigator.canPop()` 时显示），其余逻辑零改动。
- **Mock 链路全通**：MockASR（3s 一条，每 3 条 1 条 `isFinal`）→ 100ms 防抖 → MockMT（3 段流式）→ 主界面 + 悬浮窗同步显示。
- **音频内录（本轮重写，已 CI 验证）**：
  - 弃用损坏的 `system_audio_recorder 0.0.1`，改为**自研原生实现** `AudioCaptureService.kt`（345 行）。
  - 严格遵循 Android 14 顺序：先 `startForeground(TYPE_MEDIA_PROJECTION)`，再 `getMediaProjection()`。
  - `MainActivity.kt`（269 行）新增 `live_translate/audio_capture` MethodChannel + `live_translate/audio_stream` EventChannel。
  - 清单已声明 `foregroundServiceType="mediaProjection"`，新增 `ic_notification_translate.xml`。
  - 屏幕录制授权**推迟到用户点「开始」才请求**（修「一打开就弹录制框」）；MediaProjection token 每次重新申请。
- **VAD 重构（上一轮，已完成）**：
  - `lib/core/audio/vad/` 六个文件；**所有 VAD 推理在独立 Isolate**（`vad_isolate_worker.dart`），主线程零计算。
  - Silero VAD 优先（复用 `sherpa_onnx 2.0.3`，未新增插件），模型缺失/加载失败自动降级能量 VAD。
  - 修复真实 bug：旧能量 VAD `frame[i] | (frame[i+1] << 8)` 缺 int16 符号扩展，负样本被当正值、RMS 虚高 → 「误触发严重」根因。
  - 自适应噪声底 + 滞回；分段器含前导静音回补（90ms）、尾部裁剪、强制切分重叠 2 帧、`flush()` 吐末段。
- **CI 绿构建**：GitHub Actions 全流程通过，`android/build.gradle.kts` 反射式 `setCompileSdk(36)` 覆盖解决 `checkReleaseAarMetadata`。
- **模型分发通道**：GitHub Release `v1.0.0-models` 已托管 `encoder.onnx` / `decoder.onnx` / `joiner.onnx` / `tokens.txt` / `silero_vad.onnx` / `hy-mt1.5-q4_k_m.gguf`。
- **CI Release 文案一致性（P0-1 已修）**：移除 `app-release.apk` 描述与 `files:` 条目，只保留 3 个分 ABI 产物。

### ❌ 未完成 / 待办

| 项目 | 状态 | 备注 |
|------|------|------|
| **首页 / 模型导入页** | ✅ **已完成** | `home_screen.dart` + `model_import_screen.dart` + `model_storage.dart`；模型为真实检测，占位下载待后续 |
| Sherpa-ONNX ASR 接入 | ❌ 未开始 | `pubspec.yaml` 已声明 `sherpa_onnx ^2.0.3`，但**无实现类**，缺 `sherpa_asr.dart` |
| llama.cpp MT 接入 | ❌ 未开始 | 已声明 `llama_cpp_dart ^0.2.2`，缺 `llama_mt.dart` |
| 模型下载/校验管线 | ❌ 未设计 | `assets/models/` 目前**只有 `.gitkeep`**；须运行时下载 + SHA256 + 进度条（目录与就绪判定已就位） |
| 双向悬浮窗通道 | ❌ 仍单向 | `OverlayFlutterEngine.kt` 的 MethodChannel handler 全为占位 `result.success(true)` |
| 设置持久化 | ❌ 无 | 已声明 `shared_preferences` 但**代码中零引用**；字号/位置/语言重启即丢 |
| 错误恢复 / 自动重连 | ❌ 无 | 音频流 `onError` 仅打日志（`audio_capture_service.dart:165`），无重连 |
| Release 签名 | ❌ 仍用 debug 签名 | `android/app/build.gradle.kts:34` → `signingConfigs.getByName("debug")` |
| Built-in Kotlin 迁移 | ⚠️ 技术债 | `android.builtInKotlin=false` / `android.newDsl=false`，AGP 10 将移除 |
| 正式 v1.0.0 发布 | ❌ 未发布 | 需先配签名 Secrets |

---

## 3. 项目目录结构（核心业务）

```
live_translate/
├── HANDOVER.md / PROJECT_STATE.md(已过期，勿信) / pubspec.yaml
├── lib/
│   ├── main.dart                          # 入口 + 主题 + Loading/Error（110 行 home: MainScreen）
│   ├── core/
│   │   ├── engine/
│   │   │   ├── asr_engine.dart            # ASREngine + ASRResult
│   │   │   ├── mt_engine.dart             # MTEngine + MTChunk/MTResult/LanguagePair
│   │   │   ├── engine_manager.dart        # 单例注册/切换/销毁
│   │   │   ├── mock_asr.dart / mock_mt.dart
│   │   │   └── engine.dart                # 统一导出
│   │   ├── audio/
│   │   │   ├── audio_capture_service.dart # ★本轮重写：自研通道 → VAD（239 行）
│   │   │   └── vad/                       # vad_types / vad_detector / vad_segmenter
│   │   │                                  # silero_vad_backend / vad_isolate_worker / vad_service
│   │   ├── service/translation_service.dart # 编排 + 100ms 防抖 + 悬浮窗推送（387 行）
│   │   ├── model/model_storage.dart         # ★本轮新增：模型目录 / 文件规格 / 就绪检测
│   │   └── tile/quick_settings_tile.dart
│   └── ui/
│       ├── home_screen.dart               # ★本轮新增：首页（模型状态 / 引擎状态 / 双入口）
│       ├── model_import_screen.dart       # ★本轮新增：模型导入页（真实检测 + ADB 指南）
│       ├── main_screen.dart               # 控制台（846 行，已加返回按钮）★二级页
│       └── overlay_screen.dart            # 悬浮窗 overlayMain entry-point（565 行）
├── android/app/src/main/
│   ├── AndroidManifest.xml                # 含 AudioCaptureService + foregroundServiceType
│   ├── kotlin/com/example/live_translate/
│   │   ├── MainActivity.kt                # 权限 + 内录通道（269 行）
│   │   ├── AudioCaptureService.kt         # ★本轮新增：系统内录前台服务（345 行）
│   │   └── OverlayFlutterEngine.kt        # 独立进程 :overlay Engine（93 行）
│   └── res/drawable/ic_notification_translate.xml
├── test/
│   ├── vad_test.dart                      # 13 个 VAD 用例
│   ├── translation_service_test.dart
│   ├── widget_test.dart
│   └── home_screen_test.dart              # ★本轮新增：8 个首页 / 模型状态用例
└── .github/workflows/build_and_release.yml # 唯一允许的构建入口
```

---

## 4. 核心架构现状

| 组件 | 现状 | 说明 |
|------|------|------|
| 页面结构 | ✅ **首页 + 控制台 + 模型导入** | `main.dart` → `HomeScreen`（一级）→ `MainScreen` / `ModelImportScreen`（二级） |
| 模型状态检测 | ✅ **真实检测** | `ModelStorage.inspect()` 扫描私有目录，ASR+MT 齐全即就绪，VAD 可选 |
| ASR 引擎 | **Mock** | 定时产假文本，无真实推理 |
| MT 引擎 | **Mock** | 加语言前缀（`【日】`），3 段流式 |
| EngineManager | 单例就绪 | 注册/切换/销毁 + 降级回 Mock |
| TranslationService | 编排就绪 | ASR → MT → 100ms 防抖 → 字幕缓冲 + Overlay 推送 |
| AudioCaptureService | ✅ **自研原生** | MediaProjection → AudioRecord → PCM16 → EventChannel → VAD |
| VAD | ✅ Silero 优先 + 能量兜底 | 全部 isolate 执行 |
| OverlayScreen | 独立 Engine | `overlayMain()` + `@pragma('vm:entry-point')` |
| 悬浮窗通讯 | ⚠️ **单向** | 主 Engine → `shareData()` → Overlay。**反向控制未实现** |

> **结论：全链路仍绑定 Mock，无任何真实推理引擎。悬浮窗通讯为单向。**

---

## 5. 🚨 遗留报错与待修复项

### P0-1｜首页与模型导入页缺失（用户明确点名，最高优先）

- **✅ 本轮已完成（2026-11-26 02:39 UTC）**。保留此条仅为历史记录，勿重复排查。
- 原位置：`lib/main.dart:110` → 现为 `home: const HomeScreen()`。
- 现结构：首页 `HomeScreen` →「进入翻译控制台」`MainScreen`；首页同时提供「模型管理与导入」→ `ModelImportScreen`。
- 模型状态为**真实文件检测**，不伪造进度；自动下载 + SHA256 待第 3 步实现。

### P0-2｜真实引擎缺失（业务阻塞）

- `lib/core/engine/` 下**无** `sherpa_asr.dart`、**无** `llama_mt.dart`（当前仅 6 个文件：asr_engine / mt_engine / engine_manager / mock_asr / mock_mt / engine）。
- `pubspec.lock` 实锁：`sherpa_onnx 2.0.3`、`llama_cpp_dart 0.2.2`。
- `assets/models/` 仅 `.gitkeep`，**模型不在 APK 内**，必须运行时下载。

### P1｜悬浮窗双向通道未实现

- `lib/core/service/translation_service.dart:287 _sendToOverlay()` 仅调 `shareData()`（第 289 行）。
- `OverlayFlutterEngine.kt` 第 54/58/62/66/70 行 MethodChannel handler 全为占位 `result.success(true)`，停止/切语言/调字号均无法回传主引擎。

### P1｜设置无持久化

- `shared_preferences` 已在 `pubspec.yaml` 声明，但 **`lib/` 中零引用**。
- `lib/ui/overlay_screen.dart:144` 注释已标注 `// 保存设置（实际项目中应持久化到 SharedPreferences）`。

### P2｜无错误恢复 / 健康检查

- `lib/core/audio/audio_capture_service.dart:165` 音频流 `onError` 仅打日志，无重连。
- `TranslationService` 无引擎健康检查。

### P2｜Release 使用 debug 签名

- `android/app/build.gradle.kts:34` → `signingConfig = signingConfigs.getByName("debug")`。

### P3｜Built-in Kotlin 技术债

- `android/gradle.properties`：`android.builtInKotlin=false`、`android.newDsl=false`。AGP 9.3 仍支持，**AGP 10.0 将移除**。
- 现仅剩涉及插件：`quick_settings_with_flutter_plugins`（`flutter_foreground_task`、`system_audio_recorder` 已随本轮改动移除）。

### P3｜语言代码硬编码分散

- `en / ja / zh / ko` 散落于 `mock_asr.dart`、`mock_mt.dart`、`translation_service.dart`、`main_screen.dart`，缺 `LanguageRegistry`。

### 已修复（勿重复排查）

| 曾报错 | 修复方式 | 验证 |
|--------|---------|------|
| **点「录制整个屏幕」闪退 + 一打开就弹录制框** | 弃用 `system_audio_recorder 0.0.1`（5 处 Android 14 致命缺陷），改自研 `AudioCaptureService.kt`；授权推迟到点开始 | ✅ CI Run #45735984824 success |
| RELEASE 文案宣称不存在的 `app-release.apk` | 移除描述行与 `files:` 条目 | ✅ Release 实际只挂 3 个 ABI APK |
| `flutter.jar` 不存在 | CI 加 `flutter precache --android` + 残缺缓存清理 + 硬校验 | ✅ |
| `Invalid format`（GITHUB_OUTPUT 多行） | 改 heredoc `body<<RELEASE_BODY_EOF` | ✅ |
| `OverlayFlutterEngine.kt` 无 `runAppWithEntrypoint` | 改 `executeDartEntrypoint()` | ✅ |
| `checkReleaseAarMetadata` 15 项 | `android/build.gradle.kts` 反射 override `setCompileSdk(36)` | ✅ |
| 能量 VAD 负样本错判 | 正确 int16 符号扩展 + 自适应底噪 + 滞回 | ✅ `vad_test.dart` |
| 分段器误计静音帧 | `speaking` 分支仅 `isSpeech` 才自增 | ✅ `vad_test.dart` |

---

## 6. 🔑 密钥与配置继承（安全脱敏）

> **安全红线：本节仅列字段名。绝对禁止写入、索取或输出任何明文。明文由项目所有者线下保管。**

| 字段名 | 用途 | 状态 |
|--------|------|------|
| `GITHUB_TOKEN` | Actions 建 Release、上传 Artifact | 工作流引用 `${{ secrets.GITHUB_TOKEN }}`，**仓库级自动可用** |
| `KEYSTORE_BASE64` | Release 签名 `keystore.jks` 的 base64 | **需配置**（线下保管原始文件） |
| `KEY_ALIAS` | 签名 key 别名 | **需配置** |
| `STORE_PASSWORD` | keystore 密码 | **需配置** |
| `KEY_PASSWORD` | key 密码 | **需配置** |
| 模型下载 URL | Sherpa / llama 模型分发地址 | 已确定通道（Release `v1.0.0-models`） |
| 模型 SHA256 | 模型完整性校验值 | **需配置**，代码中以占位常量引用 |

> ⚠️ 历史事件：2026-11-25 曾有 PAT 在聊天中明文粘贴，**视为已泄露，必须吊销重建**（https://github.com/settings/tokens）。
> 下一个 Agent：**不得索取、不得输出任何凭据明文**，也不得把密钥写进仓库任何文件。
>
> 本地开发环境凭据现状：`gh` CLI 已登录（账号 `mingmengstar`，含 `repo`+`workflow` scope），
> 通过 `gh auth setup-git` 复用了该登录态做 git push。**未索取、未输出任何明文。**

---

## 7. ⚠️ 钢印级开发约束（不可违反）

1. **云端构建红线**：**必须且只能在 GitHub Actions 构建**。严禁在本地 / 对话环境执行 `flutter build apk`、`flutter build appbundle`、`gradlew`、`./gradlew assemble*` 等任何编译打包命令。本地**只允许**静态代码阅读、文本编辑、`dart analyze`、`flutter test`（不产 APK）。所有编译、打包、发 Release 仅在 CI 完成。
2. **防崩红线**：
   - ASR / MT / VAD 推理必须在 **Isolate** 执行，严禁阻塞 UI 线程。
   - 悬浮窗更新必须做 **100ms 防抖/节流**：`TranslationService._scheduleDebouncedUpdate`（`translation_service.dart:250` → `Duration(milliseconds: 100)`）+ `OverlayScreen._debounceTimer`（`overlay_screen.dart:128` → `50ms`）双重保险，**勿移除**。
3. **资源释放**：切引擎 / 关服务必须 `dispose()` 全部资源 —— `EngineManager.disposeAll`、`AudioCaptureService.dispose`（内含 `VadService.dispose`）、`OverlayFlutterEngine` 销毁 Engine 并从 `FlutterEngineCache` 移除。
4. **Android 14 内录顺序**：`startForeground(TYPE_MEDIA_PROJECTION)` 必须在 `getMediaProjection()` **之前**；MediaProjection token **只能消费一次**，不可缓存复用。
5. **版本锁定**：Gradle **9.5.0** / AGP **9.3.1** / Kotlin **2.4.20** / Flutter ≥ 3.47 / Dart ≥ 3.13 —— 禁止随意升降级。
6. **Mock 先行**：新增引擎必须同时提供 Mock 实现，保证 CI 无模型可跑通全链路。
7. **CI 诊断纪律**：
   - 严禁给构建步骤加 `continue-on-error: true`（会掩盖失败）。
   - CI 报错先抓完整日志（`gh run view <id> --log-failed`）通读再改，**禁止盲改连推**。
   - 每次修复只推一个焦点改动，避免多层错误混杂。

---

## 8. 下一步行动计划

### 第 1 步（接手第一件事）：修 P0-1 首页缺失 —— ✅ **本轮已完成**

**已落地**：`lib/ui/home_screen.dart`（首页）、`lib/ui/model_import_screen.dart`（模型导入）、`lib/core/model/model_storage.dart`（模型目录与就绪判定）；`main.dart` 的 `home` 已改为 `HomeScreen`。

- 首页 MVP：应用标题 + 服务状态主视觉卡 + 引擎状态卡（Mock/真实）+ 模型状态卡（真实检测）+「进入翻译控制台」+「模型管理与导入」。
- 控制台 `MainScreen` 保持原逻辑，仅新增二级页返回按钮。
- 新增 `test/home_screen_test.dart` 8 个用例，本地 `flutter test` 全绿（26/26）。

### 第 2 步：实现 `SherpaASREngine`

- 新建 `lib/core/engine/sherpa_asr.dart`，实现 `ASREngine` 接口。
- 参考 pub 缓存实测 API：`OnlineRecognizer.fromTransducer(...)`、`recognizer.createStream()`、`stream.acceptWaveform(samples: Float32List, sampleRate:)`、`recognizer.isReady(stream)` → `recognizer.decode(stream)` → `recognizer.getResult(stream)`、`recognizer.isEndpoint(stream)`。
- **推理必须在 isolate**：`sherpa_onnx` 的 FFI 绑定是 per-isolate，worker 内必须自行 `initBindings()`。

### 第 3 步：实现模型下载 + 校验管线

- 新建 `lib/core/model/model_loader.dart`：从 Release `v1.0.0-models` 下载到 `path_provider` 目录、SHA256 校验、进度回调、断点/重试。
- 首启动检测缺模型 → 引导页；**不得把模型打进 APK**（workflow 已 `rm -rf` 模型目录）。

### 第 4 步：实现 `LlamaMTEngine`

- 新建 `lib/core/engine/llama_mt.dart`，基于 `llama_cpp_dart 0.2.2`（`LlamaParent` + `isolate_child`，流式用 `completions` Stream）。同样 isolate 执行 + Mock 兜底。

### 第 5 步：双向悬浮窗通道

- `OverlayFlutterEngine.kt` 的 MethodChannel handler 落地（停止/切语言/调字号/调透明度）。
- Overlay 侧用 `MethodChannel` 主动 invoke 回传主引擎。

### 第 6 步：设置持久化 + 错误恢复

- 用已声明的 `shared_preferences` 持久化字号/位置/透明度/语言对/引擎选择。
- `TranslationService` 增加健康检查与断流重连。

### 第 7 步：正式 Release v1.0.0

- 配置 4 个签名 Secrets → 切换 `signingConfig` → 推 tag。

---

## 9. 验证基线（接手后可直接复现）

```bash
cd <workspace>
dart analyze lib test      # 期望：0 error / 0 warning，仅 7 条既有 info（material.dart deprecated）
flutter test               # 期望：26/26 passed
```

> 当前 info 全部为 Flutter 3.47.0 起 `package:flutter/material.dart` 弃用提示
> （建议改用 `package:material_ui/material_ui.dart`），非本项目代码问题。
> 本轮新增 3 个 UI 文件各贡献 1 条，故由 3 条增至 7 条。

**CI 触发方式**：`push` tag `v*` 或 `workflow_dispatch`。推 master 分支**不会**触发构建。

---

> **交接人最后提示**：截至 **2026-11-26 02:39:27 UTC**，CI 最近一次成功运行为 Run #45735984824
> （`f58760e`，tag `v0.2.1-ci-test-6`），已产出 3 个 ABI APK（arm64 42.7MB / armeabi-v7a 32.2MB / x86_64 47.6MB）。
> 本轮已补齐首页 / 模型导入页（P0-1 关闭）。剩余真正功能缺口是「真实 ASR/MT 引擎 + 悬浮窗双向通道」。
> 下一步从第 8 节第 2 步（`SherpaASREngine`）开始，**切勿本地构建，切勿索取或输出密钥明文**。

---

## 10. 本轮变更清单（2026-11-26 02:39:27 UTC）

| 文件 | 类型 | 说明 |
|------|------|------|
| `lib/core/model/model_storage.dart` | 新增 | 模型目录约定（`getApplicationSupportDirectory()/models`）、6 个必需文件规格、`inspect()` 真实检测与就绪判定 |
| `lib/ui/home_screen.dart` | 新增 | 首页：品牌头 / 服务状态主视觉 / 模型状态卡 / 引擎状态卡 / 双入口 / 下拉刷新 |
| `lib/ui/model_import_screen.dart` | 新增 | 模型导入：真实扫描、逐文件状态清单、路径复制、ADB 手动放置指引 |
| `lib/ui/main_screen.dart` | 修改 | 仅新增二级页返回按钮（`Navigator.canPop()` 判断），业务逻辑零改动 |
| `lib/main.dart` | 修改 | `home: MainScreen()` → `home: HomeScreen()`，import 同步替换 |
| `test/home_screen_test.dart` | 新增 | 8 个用例：模型规格 / 就绪判定 / 首页渲染 / Mock 标识 |

**本地验证结果**
- `dart analyze lib test` → **0 error / 0 warning**，7 条 `material.dart` 弃用 info（既有类型）。
- `flutter test` → **26/26 passed**（原 18 + 新增 8）。
- **未执行任何本地构建**（遵守云端构建红线）。

**设计取舍**
- 模型导入页**不做假进度条**：真实下载与 SHA256 尚未实现，UI 只展示真实文件检测结果，避免误导用户。
- `ModelStatus.isReady` 定义为「ASR + MT 齐全」，VAD 缺失可走能量兜底，故不阻塞就绪判定。
- 首页 `_refreshModelStatus()` 在 `initState` 中异步触发，测试环境无平台通道时返回 `hasError`，UI 优雅降级为「无法检测」，不崩溃。