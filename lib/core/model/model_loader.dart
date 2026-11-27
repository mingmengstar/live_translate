/// 模型下载管线（一键下载）
///
/// 能力：
/// - 逐文件顺序下载，实时回报**字节级**总进度（不是假进度条）
/// - **断点续传**：用 HTTP Range 从 `.part` 的已有长度继续，不重下
/// - **完整性判定**：只比对「实际写入字节数 == 服务端声明字节数」
/// - **磁盘空间预检**：空间不足在下载前就报错，不浪费流量
/// - **可取消**：取消后保留 `.part`，下次同一文件自动续传
/// - 依赖可注入（`HttpClient` / 目录），便于单元测试
///
/// ## 为什么不是 `async*` 生成器（v0.5.0 重写，勿回退）
///
/// 旧实现是 `Stream<ModelDownloadProgress> downloadPack(...) async*`。
/// 这有个致命限制：**`yield` 只能写在生成器函数体里，写不进回调**。
/// 而下载进度是在 `response.listen((chunk) {...})` 这个回调里产生的
/// —— 于是整个文件下载期间只能「默默改字段」，一个快照都推不出去。
///
/// 症状极具误导性：点「下载并安装」后界面完全静止，第一个文件
/// （`encoder-zh-en-int8.onnx`，181MB）下完才突然跳一次进度，
/// 用户会以为「下载没启动」。这是真 bug，不是体感问题。
///
/// 所以改用 `StreamController`：`_downloadOne` 的 `onProgress` 可以
/// 直接往 controller 里 `add`。同时用 [_ProgressThrottle] 做 200ms 节流，
/// 避免高速网络下每 20KB 一次快照把主 isolate 的 build 打爆。
///
/// ## v0.6.0：移除 SHA-256 校验（勿回退）
///
/// 旧实现每下完一个文件都要 `sha256.bind(file.openRead())` 全量算一遍。
/// 1.06GB 的翻译权重在手机上算一次要几十秒，界面表现为「进度 100% 后
/// 卡住不动」；更糟的是只要镜像 / 代理改写了字节，就会
/// 「下完 → 校验失败 → 删掉重下」，永远下不完。
///
/// 现在只判 `written == file.sizeBytes`。这已经能挡住截断
/// （网络中断时 `written` 必然对不上），而真正的模型损坏会在
/// `llama.cpp` / `sherpa-onnx` 加载阶段立刻报错。
library live_translate.core.model.model_loader;

import 'dart:async';
import 'dart:io';

import 'model_catalog.dart';
import 'model_storage.dart';

/// 单个文件下载状态
enum ModelFileState {
  /// 排队中
  pending,

  /// 正在下载
  downloading,

  /// 已存在且校验通过，跳过
  skipped,

  /// 下载并校验通过
  done,

  /// 失败
  failed,
}

/// 单个文件的下载结果
class ModelFileResult {
  ModelFileResult({
    required this.file,
    this.state = ModelFileState.pending,
    this.bytesForFile = 0,
    this.error,
  });

  final RemoteModelFile file;
  ModelFileState state;

  /// 该文件已完成的字节数（含续传前已有的部分）
  int bytesForFile;
  String? error;

  bool get isSuccess =>
      state == ModelFileState.done || state == ModelFileState.skipped;

  /// 0.0 ~ 1.0
  double get fraction => file.sizeBytes <= 0
      ? 0
      : (bytesForFile / file.sizeBytes).clamp(0.0, 1.0).toDouble();
}

/// 整体下载进度快照
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.packId,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.results,
    required this.isFinished,
    required this.isCancelled,
    this.currentFileName,
    this.fileIndex = 0,
    this.fileCount = 0,
    this.fatalError,
    this.bytesPerSecond = 0,
    this.remainingSeconds,
  });

  final String packId;
  final int totalBytes;

  /// 所有文件已完成字节的合计（含当前文件的实时进度）
  final int downloadedBytes;

  final List<ModelFileResult> results;
  final bool isFinished;
  final bool isCancelled;
  final String? currentFileName;

  /// 当前是第几个文件（从 1 开始）
  final int fileIndex;
  final int fileCount;
  final String? fatalError;

  /// 瞬时速度（字节/秒），0 表示还算不出来
  ///
  /// 对 1.06GB 的翻译权重来说，「还要多久」比「下了多少」更能安抚用户，
  /// 所以快照里带上速度，由 UI 决定怎么展示。
  final int bytesPerSecond;

  /// 预估剩余秒数；速度未知或已下完时为 null
  final int? remainingSeconds;

  double get fraction {
    if (totalBytes <= 0) return 0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  int get percent => (fraction * 100).round();

  bool get isSuccess => isFinished && !isCancelled && fatalError == null;

  String get downloadedLabel => RemoteModelFile.humanSize(downloadedBytes);

  String get totalLabel => RemoteModelFile.humanSize(totalBytes);

  /// 速度的人类可读形式（如 `3.4MB/s`），未知时为空串
  String get speedLabel =>
      bytesPerSecond <= 0 ? '' : '${RemoteModelFile.humanSize(bytesPerSecond)}/s';

  /// 剩余时间的人类可读形式（如 `约 4 分 12 秒`），未知时为空串
  String get remainingLabel {
    final s = remainingSeconds;
    if (s == null || s <= 0) return '';
    if (s < 60) return '约 $s 秒';
    final m = s ~/ 60;
    final rest = s % 60;
    if (m < 60) return rest == 0 ? '约 $m 分' : '约 $m 分 $rest 秒';
    final h = m ~/ 60;
    return '约 $h 小时 ${m % 60} 分';
  }
}

/// 可预期的下载异常（用户可读）
class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 进度节流器
///
/// 为什么需要：`response.listen` 在高速网络下每 20~64KB 就来一次回调，
/// 1.06GB 会产生上万次快照。每来一次都 `setState` 会让主 isolate 的
/// build 排队到卡死（本项目的悬浮窗就是靠 100ms 防抖救下来的）。
///
/// 200ms 是「肉眼看起来连续」和「一秒钟最多 5 次 build」的平衡点。
/// 文件切换 / 下载结束这类关键节点用 `force: true` 绕过节流，
/// 保证 UI 一定能收到终态。
class _ProgressThrottle {
  _ProgressThrottle(this._controller);

  final StreamController<ModelDownloadProgress> _controller;

  static const int _intervalMs = 200;

  int _lastEmitMs = 0;

  /// 最近若干次采样的 (时间, 字节)，用于算瞬时速度
  final List<({int ms, int bytes})> _samples = [];

  void emit(ModelDownloadProgress snapshot, {bool force = false}) {
    if (_controller.isClosed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastEmitMs < _intervalMs) return;
    _lastEmitMs = now;
    _controller.add(snapshot);
  }

  /// 记录一次字节采样并返回当前估算速度（字节/秒）
  ///
  /// 用「时间窗口」而不是「相邻两次」：相邻两次的间隔抖动极大
  /// （一次回调可能 1ms 也可能 300ms），算出来的速度会跳得没法看。
  /// 这里固定用最近 3 秒的窗口，窗口内不足 2 个样本时返回 0。
  int sampleSpeed(int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _samples.add((ms: now, bytes: bytes));
    // 只保留最近 3 秒
    while (_samples.length > 2 && now - _samples.first.ms > 3000) {
      _samples.removeAt(0);
    }
    if (_samples.length < 2) return 0;
    final first = _samples.first;
    final elapsedMs = now - first.ms;
    if (elapsedMs <= 0) return 0;
    final delta = bytes - first.bytes;
    if (delta <= 0) return 0;
    return (delta * 1000 / elapsedMs).round();
  }

  void reset() {
    _samples.clear();
    _lastEmitMs = 0;
  }
}

/// 模型下载器
class ModelLoader {
  ModelLoader({
    ModelStorage? storage,
    HttpClient? httpClient,
    this.maxRetries = 2,
  })  : _storage = storage ?? ModelStorage.instance,
        _ownsHttpClient = httpClient == null,
        _httpClient = httpClient ?? _createClient();

  /// 连接超时：移动网络切换 / 弱网时，不设超时会一直挂着，
  /// 用户看到的就是「进度条永远停在同一个数」。
  static HttpClient _createClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
  }

  final ModelStorage _storage;
  final HttpClient _httpClient;

  /// `_httpClient` 是不是本类创建的（只有自己创建的才该关闭）
  final bool _ownsHttpClient;

  /// 单个文件的重试次数（不含首次）
  final int maxRetries;

  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// 请求取消：当前文件在下一个数据块后停止，并保留 `.part` 供续传
  void cancel() => _cancelled = true;

  /// 释放底层连接
  ///
  /// 不调用也不会崩（GC 会回收），但 1GB 级的连接池留在那儿会占着
  /// socket 句柄，重复「取消 → 重新下载」几次就能把 fd 耗光。
  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close(force: true);
    }
  }

  /// 下载整个模型包
  ///
  /// [targetDirectory] 为空时使用 [ModelStorage] 当前目录
  /// （会尊重用户设置的自定义路径）。
  ///
  /// 用 `StreamController` 而不是 `async*`：只有这样才能把
  /// `_downloadOne` 内部 `response.listen` 回调里的中间进度推出去。
  /// 详见文件头注释。
  Stream<ModelDownloadProgress> downloadPack(
    ModelPack pack, {
    String? targetDirectory,
  }) {
    // `late final`：onListen 闭包里要引用 controller 自身，
    // 而这种引用在「声明处」是非法的（referenced_before_declaration）。
    // 闭包在 listen 时才执行，那时 controller 早已赋值，所以 late 是安全的。
    late final StreamController<ModelDownloadProgress> controller;
    controller = StreamController<ModelDownloadProgress>(
      onListen: () {
        unawaited(_runDownload(pack, targetDirectory, controller));
      },
      onCancel: () {
        // 订阅方（UI）取消：当作一次取消请求，保留 .part 供续传
        _cancelled = true;
      },
    );
    return controller.stream;
  }

  Future<void> _runDownload(
    ModelPack pack,
    String? targetDirectory,
    StreamController<ModelDownloadProgress> controller,
  ) async {
    _cancelled = false;
    final total = pack.totalBytes;
    final throttle = _ProgressThrottle(controller);

    /// 生成并投递一张快照
    void push({
      required List<ModelFileResult> results,
      required String? current,
      required int index,
      required bool finished,
      String? fatalError,
      int speed = 0,
      bool force = false,
    }) {
      final done = results.fold<int>(0, (sum, r) => sum + r.bytesForFile);
      final remaining =
          speed > 0 && total > done ? ((total - done) / speed).ceil() : null;
      throttle.emit(
        ModelDownloadProgress(
          packId: pack.id,
          totalBytes: total,
          downloadedBytes: done,
          results: List.unmodifiable(results),
          isFinished: finished,
          isCancelled: _cancelled,
          currentFileName: current,
          fileIndex: index,
          fileCount: pack.files.length,
          fatalError: fatalError,
          bytesPerSecond: speed,
          remainingSeconds: remaining,
        ),
        force: force,
      );
    }

    /// 统一收尾：保证 controller 一定被关闭，UI 的 onDone 一定触发
    Future<void> finish() async {
      if (!controller.isClosed) {
        await controller.close();
      }
    }

    // ---- 解析目标目录 ----
    Directory dir;
    try {
      if (targetDirectory != null && targetDirectory.trim().isNotEmpty) {
        dir = Directory(targetDirectory.trim());
        if (!await dir.exists()) await dir.create(recursive: true);
      } else {
        dir = await _storage.ensureDirectory();
      }
    } catch (e) {
      push(
        results: const [],
        current: null,
        index: 0,
        finished: true,
        fatalError: '无法创建模型目录：$e',
        force: true,
      );
      await finish();
      return;
    }

    // ---- 磁盘空间预检 ----
    final pending = await _pendingBytes(pack, dir);
    final free = await _freeBytes(dir);
    if (free != null && free < pending + (8 << 20)) {
      push(
        results: const [],
        current: null,
        index: 0,
        finished: true,
        fatalError: '存储空间不足：还需约 '
            '${RemoteModelFile.humanSize(pending)}，'
            '可用 ${RemoteModelFile.humanSize(free)}',
        force: true,
      );
      await finish();
      return;
    }

    final results = <ModelFileResult>[];
    var index = 0;

    for (final file in pack.files) {
      index++;

      if (_cancelled) {
        results.add(ModelFileResult(file: file));
        continue;
      }

      final target =
          File('${dir.path}${Platform.pathSeparator}${file.fileName}');

      // ---- 已存在且大小一致：直接跳过 ----
      //
      // v0.6.0 起不做 SHA-256 全量校验（原因见文件头）。
      // 大小一致即视为完整：下载时 `.part` 只有在字节数达标后才改名，
      // 所以正式文件的大小就是完整性凭证。
      if (await target.exists() && await target.length() == file.sizeBytes) {
        results.add(ModelFileResult(
          file: file,
          state: ModelFileState.skipped,
          bytesForFile: file.sizeBytes,
        ));
        push(
          results: results,
          current: file.fileName,
          index: index,
          finished: false,
          force: true,
        );
        continue;
      }

      final result = ModelFileResult(
        file: file,
        state: ModelFileState.downloading,
      );
      results.add(result);
      throttle.reset();

      // 先推一次「开始下载这个文件」，让 UI 立刻从按钮态切到进度态。
      // 不打这一下的话，用户点完「开始下载」要等到第一个 200ms 才有反应。
      push(
        results: results,
        current: file.fileName,
        index: index,
        finished: false,
        force: true,
      );

      String? lastError;
      var ok = false;

      for (var attempt = 0; attempt <= maxRetries && !_cancelled; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          throttle.reset();
        }
        try {
          await _downloadOne(
            file: file,
            target: target,
            onProgress: (bytes) {
              result.bytesForFile = bytes;
              // 这里是「进度条真的在动」的关键：把中间快照推出去。
              // 旧实现只写字段不推送，整个文件下完才跳一次。
              push(
                results: results,
                current: file.fileName,
                index: index,
                finished: false,
                speed: throttle.sampleSpeed(bytes),
              );
            },
          );

          // `_downloadOne` 内部已经用 `written != file.sizeBytes` 判过
          // 完整性（见 v0.6.0 说明），这里不再做二次校验。
          result.state = ModelFileState.done;
          result.bytesForFile = file.sizeBytes;
          ok = true;
          break;
        } catch (e) {
          lastError = e.toString();
          result.bytesForFile = 0;
          if (_cancelled) break;
        }
      }

      if (!ok) {
        result.state = ModelFileState.failed;
        result.error = _cancelled ? '已取消' : lastError;
        push(
          results: results,
          current: file.fileName,
          index: index,
          finished: true,
          fatalError:
              _cancelled ? '已取消，可稍后续传' : '${file.fileName} 下载失败：$lastError',
          force: true,
        );
        await finish();
        return;
      }

      push(
        results: results,
        current: file.fileName,
        index: index,
        finished: false,
        force: true,
      );
    }

    final allOk = results.every((r) => r.isSuccess);
    push(
      results: results,
      current: null,
      index: pack.files.length,
      finished: true,
      fatalError: _cancelled
          ? '已取消，可稍后续传'
          : (allOk ? null : '部分文件未能就绪'),
      force: true,
    );
    await finish();
  }

  /// 下载单个文件（支持续传）
  ///
  /// 先写入 `<name>.part`，全部到齐后才改名成正式文件名，
  /// 这样任何时刻看到正式文件就一定是完整文件。
  ///
  /// ## 续传的三道防线（v0.5.0）
  ///
  /// 旧实现只做了「发 Range 头」，但**从不验收**，于是三种情况全部出错：
  ///
  /// 1. 服务端返回 206 但 `Content-Range` 起点不是我们请求的偏移
  ///    （CDN 分片、代理改写、HuggingFace 的 LFS 重定向都可能出现），
  ///    此时从 `existing` 接着写会**整段错位**，文件看起来「下完了」
  ///    但 SHA-256 永远不过，然后被当成网络问题无限重试；
  /// 2. 服务端返回 416（Range Not Satisfiable）：`.part` 比声明的还大，
  ///    旧代码走 `throw HTTP 416` → 重试 → 再 416，死循环；
  /// 3. 服务端忽略 Range 直接返回 200：旧代码正确处理了（从头写），
  ///    但如果 `.part` 删除失败，会残留旧数据。
  ///
  /// 现在：校验 `Content-Range` 起始、显式处理 416、
  /// 206 但缺 `Content-Range` 时按「不可续传」处理。
  Future<void> _downloadOne({
    required RemoteModelFile file,
    required File target,
    required void Function(int bytes) onProgress,
  }) async {
    final part = File('${target.path}.part');
    var existing = 0;
    if (await part.exists()) {
      existing = await part.length();
      // 超过声明大小说明 .part 被污染，从头来
      if (existing > file.sizeBytes) {
        await _safeDelete(part);
        existing = 0;
      }
    }

    if (existing == file.sizeBytes && existing > 0) {
      if (await target.exists()) await _safeDelete(target);
      await part.rename(target.path);
      onProgress(file.sizeBytes);
      return;
    }

    onProgress(existing);

    final request = await _httpClient.getUrl(Uri.parse(file.url));
    request.headers.set(HttpHeaders.userAgentHeader, 'live-translate/1.0');
    // 显式声明不压缩：Range 请求必须按「文件字节」算偏移，
    // 中间套一层 gzip 会让 Content-Range 与实际字节错位。
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (existing > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    }

    final response = await request.close();
    var start = existing;

    if (response.statusCode == HttpStatus.partialContent) {
      // 服务端接受了续传 —— 但**必须验起始偏移**，见方法注释的防线 1。
      final contentRange = response.headers.value('content-range');
      final parsed = _parseContentRangeStart(contentRange);
      if (parsed == null || parsed != existing) {
        // 偏移对不上：宁可整份重下，也不要写出一段错位的垃圾。
        await response.drain<void>();
        await _safeDelete(part);
        await _downloadOne(file: file, target: target, onProgress: onProgress);
        return;
      }
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // 416：`.part` 已经不可用（服务端文件换了 / 大小声明过期）
      await response.drain<void>();
      await _safeDelete(part);
      await _downloadOne(file: file, target: target, onProgress: onProgress);
      return;
    } else if (response.statusCode == HttpStatus.ok) {
      // 服务端不支持 Range（或本来就没请求），只能从头写
      start = 0;
      await _safeDelete(part);
    } else {
      await response.drain<void>();
      throw ModelDownloadException('HTTP ${response.statusCode}');
    }

    final sink = part.openWrite(
      mode: start > 0 ? FileMode.append : FileMode.write,
    );

    var written = start;
    onProgress(written);

    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;

    sub = response.listen(
      (chunk) {
        if (_cancelled) {
          sub.cancel();
          if (!done.isCompleted) done.complete();
          return;
        }
        sink.add(chunk);
        written += chunk.length;
        onProgress(written);
      },
      onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      await sub.cancel().catchError((_) {});
      await sink.flush();
      await sink.close();
    }

    if (_cancelled) {
      throw ModelDownloadException('已取消');
    }

    if (written != file.sizeBytes) {
      throw ModelDownloadException(
        '下载不完整（$written/${file.sizeBytes} 字节），可续传重试',
      );
    }

    if (await target.exists()) await _safeDelete(target);
    await part.rename(target.path);
    onProgress(file.sizeBytes);
  }

  /// 解析 `Content-Range: bytes 100-999/1000` 里的起始偏移
  ///
  /// 只用于「确认服务端真的从我要的位置开始」，解析不出来一律当不可信。
  static int? _parseContentRangeStart(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(header);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// 还需下载的字节数（已存在且大小一致的视为已完成）
  Future<int> _pendingBytes(ModelPack pack, Directory dir) async {
    var total = 0;
    for (final file in pack.files) {
      final target =
          File('${dir.path}${Platform.pathSeparator}${file.fileName}');
      try {
        if (await target.exists() && await target.length() == file.sizeBytes) {
          continue;
        }
      } on FileSystemException {
        // 读不到就当需要下载
      }
      total += file.sizeBytes;
    }
    return total;
  }

  /// 目录所在分区可用字节数（拿不到就返回 null，不阻塞下载）
  Future<int?> _freeBytes(Directory dir) async {
    try {
      final result = await Process.run('df', ['-B1', dir.path]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines[1].split(RegExp(r'\s+'));
      if (cols.length < 4) return null;
      return int.tryParse(cols[3]);
    } catch (_) {
      return null;
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 忽略
    }
  }
}
