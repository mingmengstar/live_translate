/// Engine 核心库导出文件
/// 统一导出所有引擎相关的接口、实现和管理器
library live_translate.core.engine.engine;

// 接口定义
export 'asr_engine.dart';
export 'mt_engine.dart';

// 引擎管理器
export 'engine_manager.dart';

// 真实引擎（需要模型文件）
export 'sherpa_asr.dart';
export 'llama_mt.dart';

// 注意：Mock 实现（mock_asr.dart / mock_mt.dart）**不在这里导出**。
//
// 原因：v0.5.0 起运行时不再注册 Mock 引擎（见
// TranslationService.initialize 的说明），如果这里还 export，
// 任何 `import 'engine.dart'` 的文件都会把 MockASR/MockMT 拉进
// 编译图，release 构建里也会留下这些假实现。
//
// 单元测试需要它们时直接 `import 'package:live_translate/core/engine/mock_asr.dart'`，
// 精确到文件，不影响生产构建。