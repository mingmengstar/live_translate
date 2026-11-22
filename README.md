# 实时同传 - 端侧离线英日双语实时翻译悬浮窗应用

## 项目概述

实时捕获系统内部音频 → 端侧 ASR (sherpa-onnx) → 端侧翻译 (llama.cpp + Hy-MT1.5) → 悬浮窗显示字幕，全程离线零费用，P50 延迟 ≤ 500ms。

## 技术栈

| 组件 | 技术选型 | 版本 |
|------|----------|------|
| Flutter | Flutter SDK | 3.24+ / Dart 3.4+ |
| 端侧 ASR | sherpa-onnx (流式 Zipformer + Silero VAD) | 1.13.8 |
| 端侧翻译 | llama.cpp Dart 绑定 + Hy-MT1.5 GGUF | 0.9.0-dev.12 |
| 悬浮窗 | flutter_screen_overlay + 原生 Service | 1.0.7 |
| 权限/状态 | permission_handler / provider | 11.4.0 / 6.1.5 |
| 字体 | google_fonts | 6.3.3 |
| Android | minSdk 29, targetSdk 35, NDK 28.2.13676358 | - |
| Gradle | wrapper | 9.5.1 |
| AGP | Android Gradle Plugin | 9.3.1 |
| KGP | Kotlin Gradle Plugin | 2.4.20 |

## 架构设计

```
三引擎分离架构:
├── 主引擎: lib/main.dart - UI、权限、配置、Provider 状态管理
├── 前台服务: AudioCaptureService + OverlayService - 音频捕获、ASR、翻译管线、悬浮窗渲染
└── 悬浮窗引擎: lib/overlay_main.dart - 独立 Isolate 预热，原生层渲染字幕
```

## 快速开始

### 环境要求
- Flutter SDK 3.24.0+
- Android Studio Ladybug 2024.2.1+
- NDK 28.2.13676358
- JDK 17

### 安装依赖
```bash
flutter pub get
```

### 模型文件准备
请参考 [MODELS.md](MODELS.md) 下载以下模型文件并放入：
```
/data/user/0/com.example.live_translate/files/models/
├── encoder.onnx
├── decoder.onnx
├── joiner.onnx
├── tokens.txt
├── silero_vad.onnx
└── hy-mt1.5-q4_k_m.gguf
```

### 运行调试
```bash
# 连接设备后
flutter run --debug
```

### 构建发布
```bash
# Release APK (arm64-v8a 优先)
flutter build apk --release --target-platform android-arm64

# App Bundle (Google Play)
flutter build appbundle --release
```

详细构建指南请参考 [BUILD.md](BUILD.md)。

## 核心功能

1. **系统内部音频捕获** - 通过 MediaProjection + AudioRecord (REMOTE_SUBMIX) 获取 16kHz 16bit mono PCM
2. **流式语音识别** - sherpa-onnx Zipformer + Silero VAD，支持英/日双语
3. **端侧翻译** - llama.cpp 运行 Hy-MT1.5 GGUF，支持 EN⇄JA 双向翻译
4. **悬浮窗字幕** - 系统级 Overlay 窗口，支持字体大小调节、拖拽位置
5. **Quick Settings Tile** - 下拉通知栏快速开关翻译服务
6. **Material 3 深色仪表盘** - 状态监控、方向切换、字体设置、字幕预览、权限状态

## 权限要求

| 权限 | 用途 | 运行时申请 |
|------|------|------------|
| RECORD_AUDIO | 系统音频捕获 | 是 |
| SYSTEM_ALERT_WINDOW | 悬浮窗显示 | 是 (特殊权限) |
| POST_NOTIFICATIONS | 前台服务通知 (Android 13+) | 是 |
| MediaProjection | 屏幕录制/系统音频 | 是 (系统弹窗) |

## 项目结构

```
live_translate/
├── android/app/src/main/
│   ├── AndroidManifest.xml          # 权限 + 三大服务注册
│   ├── kotlin/com/example/live_translate/
│   │   ├── MainActivity.kt          # 权限桥接、MediaProjection
│   │   ├── AudioCaptureService.kt   # 前台服务：音频+AI管线
│   │   ├── OverlayService.kt        # 前台服务：悬浮窗渲染
│   │   └── TranslateTileService.kt  # Quick Settings Tile
│   └── build.gradle.kts             # arm64-v8a 优先、大文件不压缩
├── lib/
│   ├── main.dart                    # 入口、Provider、主题、根页面
│   ├── overlay_main.dart            # 悬浮窗独立引擎入口
│   ├── src/
│   │   ├── models/app_state.dart    # 状态管理
│   │   ├── services/
│   │   │   ├── audio_capture_service.dart  # 系统音频捕获 MethodChannel
│   │   │   ├── asr_service.dart            # sherpa-onnx + VAD
│   │   │   ├── translation_service.dart    # llama.cpp + Hy-MT1.5
│   │   │   ├── overlay_service.dart        # 悬浮窗显隐/更新
│   │   │   └── pipeline_service.dart       # 端到端管线编排
│   │   └── ui/
│   │       ├── dashboard_view.dart         # 仪表盘 UI
│   │       └── permission_onboarding.dart  # 权限引导
├── assets/models/                   # 模型文件目录（开发调试用）
├── MODELS.md                        # 模型下载指南
├── BUILD.md                         # 构建运行指南
└── pubspec.yaml                     # 依赖锁定
```

## 许可证合规

⚠️ **重要**: Hy-MT1.5 采用 CC-BY-NC-4.0 许可证，**仅限非商业用途**。商业项目请替换为商业友好许可证的翻译模型 (如 NLLB, Qwen2.5 等)。

| 组件 | 许可证 | 合规要求 |
|------|--------|----------|
| sherpa-onnx | Apache-2.0 | 保留版权声明 |
| llama.cpp | MIT | 保留版权声明 |
| Hy-MT1.5 | CC-BY-NC-4.0 | **仅限非商业用途** |
| Silero VAD | MIT | 保留版权声明 |
| flutter_screen_overlay | MIT | 保留版权声明 |