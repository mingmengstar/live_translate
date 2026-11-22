# 构建与运行指南

## 环境要求

- **Flutter SDK**: 3.24.0 或更高
- **Dart SDK**: 3.4.0 或更高 (随 Flutter 3.24+ 自带)
- **Android Studio**: Ladybug | 2024.2.1 或更高
- **NDK**: 28.2.13676358 (在 build.gradle.kts 中指定)
- **JDK**: 17 (Android Gradle Plugin 9.3+ 要求)
- **操作系统**: Linux / macOS / Windows (需 WSL2)

## 依赖安装

```bash
# 获取 Flutter 依赖
flutter pub get

# 检查环境
flutter doctor -v
```

## Android 构建

### Debug 构建 (开发调试)
```bash
flutter build apk --debug
# 输出: build/app/outputs/flutter-apk/app-debug.apk
```

### Release 构建 (分发)
```bash
# 构建 arm64-v8a 优先的 APK (已在 build.gradle.kts 配置 splits)
flutter build apk --release --target-platform android-arm64
# 输出: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

# 构建通用 APK (包含 arm64-v8a + armeabi-v7a)
flutter build apk --release
```

### App Bundle (Google Play 上架)
```bash
flutter build appbundle --release
# 输出: build/app/outputs/bundle/release/app-release.aab
```

## 原生层关键配置

### 权限说明 (AndroidManifest.xml)
| 权限 | 用途 | 运行时申请 |
|------|------|------------|
| RECORD_AUDIO | 录音/系统音频捕获 | 是 |
| FOREGROUND_SERVICE | 前台服务基础 | 否 |
| FOREGROUND_SERVICE_MICROPHONE | 麦克风类前台服务 | 否 |
| FOREGROUND_SERVICE_MEDIA_PROJECTION | 屏幕投影类前台服务 | 否 |
| FOREGROUND_SERVICE_DATA_SYNC | 数据同步类前台服务 | 否 |
| SYSTEM_ALERT_WINDOW | 悬浮窗显示 | 是 (特殊权限) |
| POST_NOTIFICATIONS | 通知显示 (Android 13+) | 是 |

### 服务架构
```
MainActivity (UI + 权限桥接)
    ↓ MethodChannel
AudioCaptureService (前台服务: 音频捕获 + EventChannel PCM流)
    ↓ EventChannel (16kHz 16bit mono PCM)
PipelineService (Dart端编排)
    → AsrService (sherpa-onnx 流式识别)
    → TranslationService (llama.cpp 翻译)
    ↓ MethodChannel
OverlayService (前台服务: 悬浮窗渲染)
```

## 模型部署

### 方式一: 开发调试 (assets 复制)
1. 将模型文件放入 `assets/models/`
2. 应用首启时自动复制到私有目录
3. 修改 `pipeline_service.dart` 中 `_prepareModelPaths()` 启用复制逻辑

### 方式二: 用户自行下载 (发布版推荐)
1. 应用启动检查模型文件是否存在
2. 缺失时引导用户下载 (参考 MODELS.md)
3. 用户下载后手动放入或通过应用内下载器获取

## 常见问题排查

### 1. sherpa_onnx 编译错误
```
错误: OnlineRecognizer, VoiceActivityDetector, OnlineStream 找不到
```
**解决**: sherpa_onnx 1.13.8 可能需要显式初始化绑定
```dart
// 在 main.dart 最早处添加
await SherpaOnnx.initBindingsAsync();
```
或使用实现导入:
```dart
import 'package:sherpa_onnx/src/online_recognizer.dart';
import 'package:sherpa_onnx/src/voice_activity_detector.dart';
import 'package:sherpa_onnx/src/online_stream.dart';
```

### 2. llama_cpp_dart API 不匹配
```
错误: Generator, Sampler, Request 构造参数不匹配
```
**解决**: 参考 `~/.pub-cache/hosted/pub.flutter-io.cn/llama_cpp_dart-0.9.0-dev.12/lib/` 实际导出签名重写 `TranslationService`

### 3. flutter_screen_overlay API 不匹配
```
错误: OverlayPosition 构造参数错误
```
**解决**: v1.0.7 使用位置参数 `OverlayPosition(double x, double y)`，移除 `fontFamily` 参数

### 4. 音频捕获无声音
- 确认 MediaProjection 权限已授予
- 检查 AudioRecord 采样率/声道/格式匹配 (16kHz, MONO, PCM_16BIT)
- Android 10+ 需要 `MediaRecorder.AudioSource.REMOTE_SUBMIX` + `AudioPlaybackCaptureConfiguration`

### 5. 悬浮窗不显示
- 确认 SYSTEM_ALERT_WINDOW 权限已授予
- Android 8.0+ 使用 `TYPE_APPLICATION_OVERLAY`
- 检查 WindowManager.LayoutParams FLAG 组合

### 6. 模型加载失败
- 确认文件路径正确 (私有目录 `/data/user/0/com.example.live_translate/files/models/`)
- 文件名大小写完全匹配
- 文件未损坏/完整下载
- arm64-v8a 设备无需额外 so 库

## 性能调优参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| VAD minSilenceDuration | 0.5s | 静音判断阈值 |
| VAD minSpeechDuration | 0.25s | 最短语音段 |
| 翻译 nCtx | 2048 | 上下文长度 |
| 翻译 temperature | 0.3 | 生成随机性 |
| 翻译 topK | 40 | Top-K 采样 |
| 翻译 topP | 0.95 | Top-P 采样 |
| 悬浮窗更新节流 | 500ms | 避免过度重绘 |

## 日志调试

```bash
# 查看 Flutter 日志
flutter logs

# 查看原生日志 (包含 AudioCaptureService, OverlayService)
adb logcat -s AudioCaptureService OverlayService TranslateTileService MainActivity

# 过滤特定标签
adb logcat -s "AudioCaptureService:V" "PipelineService:V"
```

## 发布检查清单

- [ ] 所有模型文件已包含或提供下载引导
- [ ] Release 模式下无 debug 打印
- [ ] 权限申请流程完整 (特别是 MediaProjection + Overlay)
- [ ] 前台服务通知图标/文案合规
- [ ] arm64-v8a / armeabi-v7a 双架构测试通过
- [ ] 内存峰值 < 2.5GB (低内存设备优雅降级)
- [ ] 电量消耗可接受 (前台服务 + AI 推理)
- [ ] 崩溃率 < 0.1% (Play Console 监控)

## 许可证合规

| 组件 | 许可证 | 合规要求 |
|------|--------|----------|
| sherpa-onnx | Apache-2.0 | 保留版权声明 |
| llama.cpp | MIT | 保留版权声明 |
| Hy-MT1.5 | CC-BY-NC-4.0 | **仅限非商业用途** |
| Silero VAD | MIT | 保留版权声明 |
| flutter_screen_overlay | MIT | 保留版权声明 |

⚠️ **重要**: Hy-MT1.5 采用 CC-BY-NC-4.0 许可证，**禁止商业使用**。商业项目请替换为商业友好许可证的翻译模型 (如 NLLB, Qwen2.5 等)。