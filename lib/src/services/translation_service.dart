import 'dart:async';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class TranslationService {
  final StreamController<String> _resultController = StreamController<String>.broadcast();

  Stream<String> get resultStream => _resultController.stream;

  LlamaContext? _context;
  LlamaModel? _model;
  Tokenizer? _tokenizer;
  String _direction = 'en2ja';
  bool _isInitialized = false;

  Future<bool> initialize({
    required String modelPath,
    int nCtx = 2048,
    int nThreads = 4,
  }) async {
    try {
      final modelParams = ModelParams(
        path: modelPath,
        gpuLayers: 0,
        useMmap: true,
        useMlock: false,
      );
      
      _model = LlamaModel.load(modelParams);
      _context = LlamaContext.create(_model!, ContextParams(
        nCtx: nCtx,
        nThreads: nThreads,
        embeddings: false,
      ));
      _tokenizer = Tokenizer(_model!.vocab);
      
      _isInitialized = true;
      return true;
    } catch (e) {
      print('TranslationService initialize error: $e');
      return false;
    }
  }

  void setDirection(String direction) {
    _direction = direction;
  }

  Future<void> translate(String text) async {
    if (!_isInitialized || _context == null || _tokenizer == null || text.trim().isEmpty) return;

    try {
      final prompt = _buildPrompt(text);
      
      // Tokenize
      final tokens = _tokenizer!.encode(prompt, addSpecial: true, parseSpecial: true);
      
      // 创建采样器参数
      final samplerParams = SamplerParams(
        topK: 40,
        topP: 0.95,
        temperature: 0.3,
      );
      
      // 创建生成请求
      final request = Request(
        promptTokens: tokens,
        maxTokens: 256,
        sampler: samplerParams,
        seqId: 0,
        startPos: 0,
      );
      
      // 创建生成器
      final generator = Generator(_context!, _tokenizer!);
      
      final buffer = StringBuffer();
      await for (final event in generator.run(request)) {
        if (event is TokenEvent) {
          buffer.write(event.text);
          _resultController.add(buffer.toString());
        } else if (event is DoneEvent) {
          break;
        }
      }
    } catch (e) {
      print('TranslationService translate error: $e');
    }
  }

  String _buildPrompt(String text) {
    if (_direction == 'en2ja') {
      return '''Below is an instruction that describes a task. Write a response that appropriately completes the request.

### Instruction:
Translate the following English text to Japanese. Only output the translation.

### Input:
$text

### Response:
''';
    } else {
      return '''以下はタスクを説明する指示です。リクエストを適切に完了する応答を書いてください。

### 指示:
以下の日本語を英語に翻訳してください。翻译のみを出力してください。

### 入力:
$text

### 応答:
''';
    }
  }

  void dispose() {
    _context?.dispose();
    _model?.dispose();
    _resultController.close();
    _isInitialized = false;
  }
}