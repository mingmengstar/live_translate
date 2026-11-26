/// 模型导入 / 状态说明页
///
/// 当前阶段说明：
/// - 模型**不打包进 APK**（CI 已剔除 assets/models 下的权重文件）；
/// - 自动下载 + SHA256 校验管线在下一阶段实现（`ModelLoader`）；
/// - 本页先提供**真实的状态检测**与手动放置说明，不做假进度条。
library live_translate.ui.model_import_screen;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:live_translate/core/model/model_storage.dart';

class ModelImportScreen extends StatefulWidget {
  const ModelImportScreen({super.key});

  @override
  State<ModelImportScreen> createState() => _ModelImportScreenState();
}

class _ModelImportScreenState extends State<ModelImportScreen> {
  ModelStatus? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final status = await ModelStorage.instance.inspect();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  Future<void> _copyPath() async {
    final path = _status?.directoryPath;
    if (path == null || path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('模型目录路径已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        title: const Text('模型导入'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '重新检测',
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          color: Colors.blue,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildIntroCard(),
              const SizedBox(height: 16),
              _buildStatusCard(),
              const SizedBox(height: 16),
              _buildFileListCard(),
              const SizedBox(height: 16),
              _buildManualGuideCard(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部说明
  Widget _buildIntroCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.blue.withValues(alpha: 0.18),
            const Color(0xFF1E1E1E),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.inventory_2_rounded,
                  color: Colors.blue,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '模型需单独获取',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '为控制安装包体积，ASR / MT / VAD 权重文件不随 APK 分发。'
            '请从模型发布通道下载后放入下方目录，App 会在启动时自动检测。',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.construction_rounded,
                  size: 16,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '一键下载与 SHA256 校验正在开发中，当前请手动放置模型文件。',
                    style: TextStyle(
                      color: Colors.orange[200],
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 检测状态
  Widget _buildStatusCard() {
    final status = _status;
    final ready = status?.isReady ?? false;

    final Color accent;
    final String title;
    final String subtitle;
    if (_loading) {
      accent = Colors.grey;
      title = '正在检测...';
      subtitle = '扫描模型目录';
    } else if (status == null || status.hasError) {
      accent = Colors.orangeAccent;
      title = '无法检测模型';
      subtitle = status?.error ?? '未知错误';
    } else if (ready) {
      accent = Colors.greenAccent;
      title = '模型已就绪';
      subtitle = 'ASR 与 MT 模型均已检测到';
    } else {
      accent = Colors.orangeAccent;
      title = '模型不完整';
      subtitle = '已检测 ${status.presentCount}/${status.totalCount} 个文件';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                  ),
                )
              else
                Icon(
                  ready
                      ? Icons.check_circle_rounded
                      : Icons.error_outline_rounded,
                  color: accent,
                  size: 20,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!_loading && status != null && !status.hasError)
                Text(
                  '${status.presentCount}/${status.totalCount}',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
              height: 1.5,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (status != null && status.directoryPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: _copyPath,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_open_rounded,
                        size: 16, color: Colors.grey[400]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status.directoryPath,
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.copy_rounded, size: 14, color: Colors.grey[500]),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 文件清单
  Widget _buildFileListCard() {
    final present = _status?.presentFiles.toSet() ?? const <String>{};

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_rounded,
                  size: 18, color: Colors.blue[300]),
              const SizedBox(width: 8),
              const Text(
                '必需文件',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...ModelStorage.requiredFiles.map((spec) {
            final exists = present.contains(spec.fileName);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    exists
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 16,
                    color: exists ? Colors.greenAccent : Colors.grey[700],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          spec.label,
                          style: TextStyle(
                            color: exists ? Colors.white : Colors.grey[400],
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          spec.fileName,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (exists ? Colors.green : Colors.grey)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      exists ? '已就绪' : '缺失',
                      style: TextStyle(
                        color: exists ? Colors.greenAccent : Colors.grey[500],
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// 手动放置说明
  Widget _buildManualGuideCard() {
    const codeStyle = TextStyle(
      color: Colors.greenAccent,
      fontSize: 11,
      fontFamily: 'monospace',
      height: 1.6,
    );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded, size: 18, color: Colors.blue[300]),
              const SizedBox(width: 8),
              const Text(
                '手动导入（ADB）',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '1. 从模型发布通道下载全部文件；\n'
            '2. 打开手机 USB 调试并连接电脑；\n'
            '3. 执行以下命令（路径中的 <包名> 按实际替换）：',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0D0D),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: const SelectableText(
              'adb push encoder.onnx  /sdcard/Android/data/<包名>/files/models/\n'
              'adb push decoder.onnx  /sdcard/Android/data/<包名>/files/models/\n'
              'adb push joiner.onnx   /sdcard/Android/data/<包名>/files/models/\n'
              'adb push tokens.txt    /sdcard/Android/data/<包名>/files/models/\n'
              'adb push silero_vad.onnx /sdcard/Android/data/<包名>/files/models/\n'
              'adb push hy-mt1.5-q4_k_m.gguf /sdcard/Android/data/<包名>/files/models/',
              style: codeStyle,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '提示：放入文件后回到本页下拉刷新（或点右上角刷新）即可重新检测。',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}