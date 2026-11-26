/// Engine 核心库导出文件
/// 统一导出所有引擎相关的接口、实现和管理器
library live_translate.core.engine.engine;

// 接口定义
export 'asr_engine.dart';
export 'mt_engine.dart';

// 引擎管理器
export 'engine_manager.dart';

// Mock 实现（开发调试用）
export 'mock_asr.dart';
export 'mock_mt.dart';

// 真实引擎（需要模型文件；加载失败自动降级 Mock）
export 'sherpa_asr.dart';
export 'llama_mt.dart';