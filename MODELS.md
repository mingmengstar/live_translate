# 模型文件下载指南

本项目需要以下模型文件才能正常运行。请下载并放置到应用私有目录（首次启动时会自动创建）：
`/data/user/0/com.example.live_translate/files/models/`

## 1. ASR 模型 - sherpa-onnx 流式 Zipformer (英文+日文)

### 下载地址
- **GitHub Release**: https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
- 或从 HuggingFace: https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-ja-2023-06-26

### 所需文件
```
encoder.onnx          # 编码器模型 (~45MB)
decoder.onnx          # 解码器模型 (~8MB)
joiner.onnx           # Joiner 模型 (~4MB)
tokens.txt            # 词表文件
silero_vad.onnx       # Silero VAD 模型 (~1.5MB)
```

### 模型说明
- 支持英语和日语的流式识别
- 采样率: 16kHz
- 特征维度: 80
- 适合实时语音识别场景

## 2. 翻译模型 - Hy-MT1.5 GGUF

### 下载地址
- **HuggingFace**: https://huggingface.co/ilyabond/hy-mt1.5-gguf
- 推荐量化版本: `hy-mt1.5-q4_k_m.gguf` (~1.2GB)

### 模型说明
- 双语翻译模型（英⇄日）
- 支持指令微调格式
- 推荐上下文长度: 2048 tokens
- 量化等级: Q4_K_M (平衡质量与速度)

## 3. 文件结构

首次启动后，应用会创建以下目录结构：
```
/data/user/0/com.example.live_translate/files/
├── models/
│   ├── encoder.onnx
│   ├── decoder.onnx
│   ├── joiner.onnx
│   ├── tokens.txt
│   ├── silero_vad.onnx
│   └── hy-mt1.5-q4_k_m.gguf
```

## 4. 替代方案

如果无法下载上述模型，可尝试以下替代：

### ASR 替代模型
- **更小模型**: sherpa-onnx-streaming-zipformer-en-2023-06-26 (仅英文，约 30MB)
- **多语言**: sherpa-onnx-streaming-zipformer-multi-2023-06-26 (支持 13 种语言)

### 翻译替代模型
- **更小模型**: qwen2.5-0.5b-instruct-q4_k_m.gguf (~400MB) - 需要调整提示词
- **NLLB**: nllb-200-distilled-600m-q4_k_m.gguf (~400MB) - Facebook 多语言翻译

## 5. 验证模型

下载后，可使用以下命令验证模型完整性：
```bash
# 检查文件大小
ls -lh models/

# 验证 ONNX 模型
python -c "import onnx; onnx.checker.check_model(onnx.load('models/encoder.onnx')); print('encoder OK')"

# 验证 GGUF 模型
llama-cli -m models/hy-mt1.5-q4_k_m.gguf --version
```

## 6. 注意事项

1. **文件名必须完全匹配** 代码中的路径（区分大小写）
2. **不要解压** .onnx 和 .gguf 文件，直接使用
3. **arm64-v8a 设备** 可直接运行，无需额外编译
4. **内存要求**: 运行时约需 2-3GB 可用内存（ASR + 翻译同时加载）
5. **存储空间**: 模型总计约 1.5GB，建议预留 3GB 空间

## 7. 开发调试

开发期间可将模型文件放在 `assets/models/` 目录下，应用启动时会自动复制到私有目录。但发布版本建议让用户自行下载（版权/体积原因）。