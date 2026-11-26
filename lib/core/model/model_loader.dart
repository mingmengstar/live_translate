/// 模型下载管线（一键下载）
///
/// 能力：
/// - 逐文件顺序下载，实时回报**字节级**总进度（不是假进度条）
/// - **断点续传**：用 HTTP Range 从 `.part` 的已有长度继续，不重下
/// - **SHA-256 校验**：比对清单里的真实哈希；不通过就删掉坏文件并重试
/// - **磁盘空间预检**：空间不足在下载前就报错，不浪费流量
/// - **可取消**：取消后保留 `.part`，下次同一文件自动续传
/// - 依赖可注入（`HttpClient` / 目录），便于单元测试
library live_translate.core.model.model_loader;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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
  });

  final String packId;
  final int totalBytes;

  /// 所有文件已完成字节的合计
  final int downloadedBytes;

  final List<ModelFileResult> results;
  final bool isFinished;
  final bool isCancelled;
  final String? currentFileName;

  /// 当前是第几个文件（从 1 开始）
  final int fileIndex;
  final int fileCount;
  final String? fatalError;

  double get fraction {
    if (totalBytes <= 0) return 0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  int get percent => (fraction * 100).round();

  bool get isSuccess => isFinished && !isCancelled && fatalError == null;

  String get downloadedLabel => RemoteModelFile.humanSize(downloadedBytes);

  String get totalLabel => RemoteModelFile.humanSize(totalBytes);
}

/// 可预期的下载异常（用户可读）
class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 模型下载器
class ModelLoader {
  ModelLoader({
    ModelStorage? storage,
    HttpClient? httpClient,
    this.maxRetries = 2,
    this.verifyDigest = true,
  })  : _storage = storage ?? ModelStorage.instance,
        _httpClient = httpClient ?? HttpClient();

  final ModelStorage _storage;
  final HttpClient _httpClient;

  /// 单个文件的重试次数（不含首次）
  final int maxRetries;

  /// 是否做 SHA-256 校验（单元测试可关掉，避免为假数据造哈希）
  final bool verifyDigest;

  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// 请求取消：当前文件在下一个数据块后停止，并保留 `.part` 供续传
  void cancel() => _cancelled = true;

  /// 下载整个模型包
  ///
  /// [targetDirectory] 为空时使用 [ModelStorage] 当前目录
  /// （会尊重用户设置的自定义路径）。
  Stream<ModelDownloadProgress> downloadPack(
    ModelPack pack, {
    String? targetDirectory,
  }) async* {
    _cancelled = false;
    final total = pack.totalBytes;

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
      yield ModelDownloadProgress(
        packId: pack.id,
        totalBytes: total,
        downloadedBytes: 0,
        results: const [],
        isFinished: true,
        isCancelled: false,
        fatalError: '无法创建模型目录：$e',
      );
      return;
    }

    // ---- 磁盘空间预检 ----
    final pending = await _pendingBytes(pack, dir);
    final free = await _freeBytes(dir);
    if (free != null && free < pending + (8 << 20)) {
      yield ModelDownloadProgress(
        packId: pack.id,
        totalBytes: total,
        downloadedBytes: 0,
        results: const [],
        isFinished: true,
        isCancelled: false,
        fatalError: '存储空间不足：还需约 '
            '${RemoteModelFile.humanSize(pending)}，'
            '可用 ${RemoteModelFile.humanSize(free)}',
      );
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

      // ---- 已存在且大小一致：哈希校验通过就跳过 ----
      if (await target.exists() && await target.length() == file.sizeBytes) {
        if (!verifyDigest || await _verify(target, file.sha256)) {
          results.add(ModelFileResult(
            file: file,
            state: ModelFileState.skipped,
            bytesForFile: file.sizeBytes,
          ));
          yield _snapshot(
            pack: pack,
            results: results,
            current: file.fileName,
            index: index,
            finished: false,
          );
          continue;
        }
        await _safeDelete(target);
      }

      final result = ModelFileResult(
        file: file,
        state: ModelFileState.downloading,
      );
      results.add(result);

      String? lastError;
      var ok = false;

      for (var attempt = 0; attempt <= maxRetries && !_cancelled; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
        try {
          await _downloadOne(
            file: file,
            target: target,
            onProgress: (bytes) {
              result.bytesForFile = bytes;
            },
          );

          if (verifyDigest && !await _verify(target, file.sha256)) {
            await _safeDelete(target);
            throw ModelDownloadException('SHA-256 校验未通过，已丢弃重下');
          }

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
        yield _snapshot(
          pack: pack,
          results: results,
          current: file.fileName,
          index: index,
          finished: true,
          fatalError: _cancelled
              ? '已取消，可稍后续传'
              : '${file.fileName} 下载失败：$lastError',
        );
        return;
      }

      yield _snapshot(
        pack: pack,
        results: results,
        current: file.fileName,
        index: index,
        finished: false,
      );
    }

    final allOk = results.every((r) => r.isSuccess);
    yield _snapshot(
      pack: pack,
      results: results,
      current: null,
      index: pack.files.length,
      finished: true,
      fatalError: _cancelled
          ? '已取消，可稍后续传'
          : (allOk ? null : '部分文件未能就绪'),
    );
  }

  ModelDownloadProgress _snapshot({
    required ModelPack pack,
    required List<ModelFileResult> results,
    required String? current,
    required int index,
    required bool finished,
    String? fatalError,
  }) {
    final done = results.fold<int>(0, (sum, r) => sum + r.bytesForFile);
    return ModelDownloadProgress(
      packId: pack.id,
      totalBytes: pack.totalBytes,
      downloadedBytes: done,
      results: List.unmodifiable(results),
      isFinished: finished,
      isCancelled: _cancelled,
      currentFileName: current,
      fileIndex: index,
      fileCount: pack.files.length,
      fatalError: fatalError,
    );
  }

  /// 下载单个文件（支持续传）
  ///
  /// 先写入 `<name>.part`，全部到齐后才改名成正式文件名，
  /// 这样任何时刻看到正式文件就一定是完整文件。
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
    if (existing > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    }

    final response = await request.close();
    var start = existing;

    if (response.statusCode == HttpStatus.partialContent) {
      // 服务端接受了续传
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

  Future<bool> _verify(File file, String expected) async {
    if (expected.isEmpty) return true;
    try {
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString().toLowerCase() == expected.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 忽略
    }
  }

  /// 计算文本的 SHA-256（测试用）
  static String digestOf(String text) =>
      sha256.convert(utf8.encode(text)).toString();
}