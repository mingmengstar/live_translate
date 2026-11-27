/// 模型管理 / 导入 / 一键下载页
///
/// 本页提供三条互补的路径：
/// 1. **一键下载**：按语种选择模型包，自动下载全部必要组件并做 SHA-256 校验；
/// 2. **自由目录**：模型目录不再固定，用户可选任意文件夹（含 SD 卡 / 下载目录）；
/// 3. **手动放置**：给习惯 ADB / 文件管理器的用户保留说明。
///
/// 所有进度条都绑定真实字节数，不做假动画。
library live_translate.ui.model_import_screen;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:live_translate/core/model/model_catalog.dart';
import 'package:live_translate/core/model/model_loader.dart';
import 'package:live_translate/core/model/model_storage.dart';
import 'package:live_translate/core/service/app_settings.dart';
import 'package:live_translate/core/service/translation_service.dart';

class ModelImportScreen extends StatefulWidget {
  const ModelImportScreen({super.key});

  @override
  State<ModelImportScreen> createState() => _ModelImportScreenState();
}

class _ModelImportScreenState extends State<ModelImportScreen> {
  ModelStatus? _status;
  bool _loading = true;

  /// 当前选择的识别模型语种
  AsrModelVariant _variant = AsrModelVariant.zhEn;

  /// 当前选择的翻译模型
  MtModelVariant _mtVariant = MtModelVariant.hyMt15Q4;

  /// 是否附带翻译模型
  bool _withTranslation = true;

  /// 是否附带 VAD
  bool _withVad = true;

  /// 下载中
  bool _downloading = false;

  /// 最近一次进度快照
  ModelDownloadProgress? _progress;

  /// 下载器（用于取消）
  ModelLoader? _loader;

  StreamSubscription<ModelDownloadProgress>? _downloadSub;

  @override
  void initState() {
    super.initState();
    // 恢复上次选择的模型组合（幂等，失败保持默认值）
    _restoreSelection();
    _refresh();
  }

  /// 从持久化恢复「上次选了哪个语种 / 哪个翻译模型 / 要不要 VAD」
  ///
  /// 不恢复的话，用户每次进来都得从默认值重新选一遍 ——
  /// 而下载 4.3GB 的 7B 模型显然不是「随手点一下」的操作。
  Future<void> _restoreSelection() async {
    final store = AppSettingsStore.instance;
    await store.load();
    if (!mounted) return;
    setState(() {
      _variant = store.asrVariant;
      _mtVariant = store.mtVariant;
      _withVad = store.withVad;
    });
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _loader?.cancel();
    super.dispose();
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

  // ---------------------------------------------------------------------------
  // 目录选择（自由路径）
  // ---------------------------------------------------------------------------

  /// 选择任意目录作为模型目录
  ///
  /// 说明：Android 10+ 的分区存储不允许直接把任意 URI 当普通路径读写，
  /// 因此这里允许用户**手输绝对路径**（如 SD 卡或 Download 下的目录），
  /// 同时提供「填入常见路径」快捷项，避免用户无路可循。
  ///
  /// ## 为什么要这么小心地处理键盘（v0.5.0 修复）
  ///
  /// 旧实现是 `AlertDialog(content: Column(...))`。这有个真机必现的 UI 问题：
  ///
  /// - `AlertDialog` 把 `content` 放进一个 `Flexible` 里；
  /// - 输入法弹出时 `windowSoftInputMode="adjustResize"` 会让可用高度骤减；
  /// - 但 `Column(mainAxisSize: MainAxisSize.min)` **不会自动滚动**，
  ///   只能被压缩 —— 于是文字被挤得上下位移，`Wrap` 里的路径芯片挤成
  ///   两行/三行，整个对话框「变形」。
  ///
  /// 三条修复（缺一不可）：
  /// 1. `content` 外面套 `SingleChildScrollView` —— 空间不够就滚动，
  ///    而不是压缩子节点（这是标准做法）；
  /// 2. `insetPadding` 给足左右/上下留白，避免边距被键盘顶到 0；
  /// 3. 用 `MediaQuery.viewInsetsOf(context).bottom` 让对话框整体上移，
  ///    输入框不会被键盘盖住。
  ///
  /// 另外顺手补上 `controller.dispose()`：`TextEditingController` 是
  /// 需要释放的资源，旧实现每打开一次对话框就漏一个。
  Future<void> _pickDirectory() async {
    final controller = TextEditingController(
      text: _status?.directoryPath ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          // 内边距：左右至少 16，避免贴到屏幕边缘。
          // 上下留白交给 Dialog 自带的 AnimatedPadding 处理 ——
          // 它会读 viewInsets 把对话框整体推到键盘上方，
          // 这里再手算一次反而会叠加、把小屏挤得更惨。
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text('设置模型目录', style: TextStyle(color: Colors.white)),
          // 关键：可滚动 + min 尺寸。两者必须同时存在，
          // 只写 min 会被压缩，只写 scroll 会让对话框占满高度。
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '填写模型所在的绝对路径，App 会从中读取模型文件。'
                  '留空则恢复默认的私有目录。',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  // 单行：路径是单行的，允许多行会让回车变成换行而不是提交
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (value) =>
                      Navigator.of(dialogContext).pop(value),
                  decoration: InputDecoration(
                    hintText: '/storage/emulated/0/Download/models',
                    hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '常见位置',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    '/storage/emulated/0/Download/models',
                    '/storage/emulated/0/Android/data/com.example.live_translate/files/models',
                  ].map((p) {
                    return ActionChip(
                      label: Text(
                        '${p.split('/').take(5).join('/')}/…',
                        style: TextStyle(color: Colors.grey[400], fontSize: 10),
                      ),
                      backgroundColor: const Color(0xFF2A2A2A),
                      side: const BorderSide(color: Colors.white10),
                      onPressed: () {
                        controller.text = p;
                        // 手动把光标放到末尾：赋值不会自动移动光标，
                        // 用户接着输入就会插到中间，很别扭。
                        controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: controller.text.length),
                        );
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('取消', style: TextStyle(color: Colors.grey[500])),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('__reset__'),
              child: const Text('恢复默认', style: TextStyle(color: Colors.orangeAccent)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('应用'),
            ),
          ],
        );
      },
    );

    // 对话框已关闭，控制器不再需要；不释放会一直持有监听与文本缓冲
    controller.dispose();

    if (result == null) return;

    if (result == '__reset__') {
      await ModelStorage.instance.setCustomDirectory(null);
    } else {
      final path = result.toString().trim();
      await ModelStorage.instance.setCustomDirectory(path.isEmpty ? null : path);
    }

    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ModelStorage.instance.isUsingCustomPath
              ? '已切换模型目录为 ${ModelStorage.instance.customPath}'
              : '已恢复默认模型目录',
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 一键下载
  // ---------------------------------------------------------------------------

  Future<void> _startDownload() async {
    if (_downloading) return;

    final pack = ModelCatalog.pack(
      variant: _variant,
      mtVariant: _mtVariant,
      withTranslation: _withTranslation,
      withVad: _withVad,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('开始下载', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pack.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '共 ${pack.files.length} 个文件，合计约 ${pack.totalSizeLabel}。',
              style: TextStyle(color: Colors.grey[400], fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 8),
            Text(
              '下载完成后会比对文件大小做完整性检查。'
              '中途取消可保留已下载部分，下次继续。',
              style: TextStyle(color: Colors.grey[600], fontSize: 11, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('取消', style: TextStyle(color: Colors.grey[500])),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // 记住这次选的组合：下次进来还是它，不用重新点
    unawaited(AppSettingsStore.instance.saveModelChoice(
      asrVariant: _variant,
      mtVariant: _mtVariant,
      withVad: _withVad,
    ));

    final loader = ModelLoader();
    _loader = loader;
    setState(() {
      _downloading = true;
      _progress = null;
    });

    _downloadSub = loader
        .downloadPack(pack)
        .listen(
          (p) {
            if (!mounted) return;
            setState(() => _progress = p);
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _downloading = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('下载异常：$e')),
            );
          },
          onDone: () async {
            if (!mounted) return;
            setState(() => _downloading = false);
            await _refresh();
            // 下载管线正常结束时 onDone 只代表「流关了」，还要看最后一张
            // 快照是不是成功。失败/取消时也走 onDone，不能一律提示成功。
            if (!mounted) return;
            final last = _progress;
            if (last != null && last.fatalError != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(last.fatalError!),
                  action: SnackBarAction(
                    label: '重试',
                    onPressed: _startDownload,
                  ),
                ),
              );
              return;
            }

            // ---- v0.6.0：真正执行「热切换到真实引擎」 ----
            //
            // 旧实现只弹一句「已切换到真实引擎」，实际什么也没做 ——
            // 用户必须杀进程重开才能用上刚下的模型。
            // 现在调 TranslationService.reloadEngines()：内部
            // disposeAll → 重新注册 → 重新 switch，全程不重启 App。
            await _reloadEnginesAfterDownload();
          },
        );
  }

  void _cancelDownload() {
    _loader?.cancel();
  }

  /// 下载完成后把引擎热切换成刚下好的真实引擎
  ///
  /// ## 为什么不能只弹提示
  ///
  /// 下载完成时 `TranslationService` 里很可能还是「未加载」状态
  /// （用户在下载前就打开过 App）。只弹一句「已切换到真实引擎」而不做事，
  /// 用户回到主界面依然看到「未加载」，会以为下载白做了。
  ///
  /// ## 失败也要说清楚
  ///
  /// 常见失败：
  /// - `armeabi-v7a` / `x86_64` 的 APK 里没有 llama.cpp 原生库 → MT 加载必失败；
  /// - 下载的是「只识别」包 → 没有 MT 权重。
  ///
  /// 这两种情况下 `reloadEngines()` 返回 false，但 `engineNote` 里
  /// 有具体原因，直接展示给用户，不要糊一句「切换失败」。
  Future<void> _reloadEnginesAfterDownload() async {
    // 本页是从 HomeScreen push 上来的，Provider 在祖先上，
    // 用 `read` 取实例（`watch` 会在这里造成无谓重建）。
    final service = context.read<TranslationService>();
    try {
      final ok = await service.reloadEngines();
      if (!mounted) return;

      final note = service.engineNote;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? '模型下载完成，已切换到真实引擎'
                : '模型已下载，但引擎未能加载：${note ?? '原因未知'}',
          ),
          duration: Duration(seconds: ok ? 4 : 8),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('模型已下载，但切换引擎失败：$e')),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        title: const Text('模型管理'),
        actions: [
          IconButton(
            onPressed: _loading || _downloading ? null : _refresh,
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
              _buildStatusCard(),
              const SizedBox(height: 16),
              _buildDownloadCard(),
              const SizedBox(height: 16),
              _buildDirectoryCard(),
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

  /// 当前检测状态
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
      subtitle = '识别与翻译组件均已检测到，可以启用真实引擎';
    } else if (!status.hasAnyAsrFile && !status.mtReady) {
      accent = Colors.orangeAccent;
      title = '尚未安装模型';
      subtitle = '尚未安装任何模型，请在下方一键下载后才能开始翻译';
    } else {
      accent = Colors.orangeAccent;
      title = '模型不完整';
      subtitle = '已检测 ${status.presentCount} 个相关文件，'
          '还缺必要组件（识别四件套 + 翻译权重）';
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
                  ready ? Icons.check_circle_rounded : Icons.error_outline_rounded,
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
                Row(
                  children: [
                    if (status.asrReady)
                      _miniBadge('ASR', Colors.greenAccent),
                    if (status.mtReady) _miniBadge('MT', Colors.greenAccent),
                    if (status.vadReady) _miniBadge('VAD', Colors.blueAccent),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: Colors.grey[500], fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _miniBadge(String label, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
      ),
    );
  }

  /// 一键下载卡片
  Widget _buildDownloadCard() {
    final pack = ModelCatalog.pack(
      variant: _variant,
      mtVariant: _mtVariant,
      withTranslation: _withTranslation,
      withVad: _withVad,
    );
    final progress = _progress;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.blue.withValues(alpha: 0.12),
            const Color(0xFF1E1E1E),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_download_rounded, size: 18, color: Colors.blue[300]),
              const SizedBox(width: 8),
              const Text(
                '一键下载必要组件',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '一次装齐识别模型、语音活动检测与翻译模型。'
            '若只想先试用，可关掉「翻译模型」只下识别部分。',
            style: TextStyle(color: Colors.grey[600], fontSize: 11, height: 1.6),
          ),
          const SizedBox(height: 14),

          // 语种选择
          Text(
            '识别语种',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: AsrModelVariant.values.map((v) {
              final selected = v == _variant;
              return ChoiceChip(
                label: Text(
                  ModelCatalog.asrVariantLabels[v] ?? v.name,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.grey[300],
                    fontSize: 12,
                  ),
                ),
                selected: selected,
                onSelected: _downloading
                    ? null
                    : (_) => setState(() => _variant = v),
                selectedColor: Colors.blue.withValues(alpha: 0.3),
                backgroundColor: const Color(0xFF2A2A2A),
                side: BorderSide(
                  color: selected ? Colors.blue : Colors.white10,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
          Text(
            ModelCatalog.asrVariantDetails[_variant] ?? '',
            style: TextStyle(color: Colors.grey[600], fontSize: 11, height: 1.5),
          ),

          const SizedBox(height: 12),

          // 可选组件
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _withVad,
            onChanged: _downloading
                ? null
                : (v) => setState(() => _withVad = v),
            title: Text(
              '语音活动检测（Silero VAD）',
              style: TextStyle(color: Colors.grey[300], fontSize: 12),
            ),
            subtitle: Text(
              '约 629KB。装它能减少静音段的无效识别；不装则自动用能量检测兜底。',
              style: TextStyle(color: Colors.grey[600], fontSize: 10, height: 1.5),
            ),
            activeThumbColor: Colors.blue,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _withTranslation,
            onChanged: _downloading
                ? null
                : (v) => setState(() => _withTranslation = v),
            title: Text(
              '翻译模型（${ModelCatalog.mtSpec(_mtVariant).label}）',
              style: TextStyle(color: Colors.grey[300], fontSize: 12),
            ),
            subtitle: Text(
              '${ModelCatalog.mtSpec(_mtVariant).description}'
              '不装则只能看到原文，无法翻译。',
              style: TextStyle(color: Colors.grey[600], fontSize: 10, height: 1.5),
            ),
            activeThumbColor: Colors.blue,
          ),

          // 翻译模型选择：不同模型的体积/质量/内存需求差 10 倍，
          // 必须让用户自己选，不能写死一个。
          if (_withTranslation) ...[
            const SizedBox(height: 4),
            Text(
              '翻译模型',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: MtModelVariant.values.map((v) {
                final selected = v == _mtVariant;
                final spec = ModelCatalog.mtSpec(v);
                return ChoiceChip(
                  label: Text(
                    spec.label,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.grey[300],
                      fontSize: 11,
                    ),
                  ),
                  selected: selected,
                  onSelected: _downloading
                      ? null
                      : (_) => setState(() => _mtVariant = v),
                  selectedColor: Colors.purple.withValues(alpha: 0.35),
                  backgroundColor: const Color(0xFF2A2A2A),
                  side: BorderSide(
                    color: selected ? Colors.purpleAccent : Colors.white10,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 6),
            Text(
              ModelCatalog.mtSpec(_mtVariant).description,
              style: TextStyle(color: Colors.grey[600], fontSize: 10, height: 1.5),
            ),
          ],

          const SizedBox(height: 8),

          // 体积汇总
          Row(
            children: [
              Icon(Icons.data_usage_rounded, size: 14, color: Colors.grey[500]),
              const SizedBox(width: 6),
              Text(
                '合计约 ${pack.totalSizeLabel} · ${pack.files.length} 个文件',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // 进度 / 按钮
          if (progress != null && (_downloading || progress.isFinished)) ...[
            _buildProgress(progress),
            const SizedBox(height: 12),
          ],

          SizedBox(
            width: double.infinity,
            height: 46,
            child: _downloading
                ? OutlinedButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('取消下载'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orangeAccent,
                      side: BorderSide(
                        color: Colors.orangeAccent.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: _startDownload,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      progress != null && progress.isCancelled
                          ? '继续下载'
                          : '下载并安装',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.blue,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 真实进度展示
  ///
  /// 三层信息，从「发生了什么」到「还要多久」逐级递进：
  /// 1. 状态文本（正在下载 xxx / 已取消 / 完成）
  /// 2. 字节数 + 百分比 + 速度 + 剩余时间
  /// 3. 文件级进度（第 3/5 个）
  ///
  /// 1.06GB 的翻译权重在普通网络下要下十几分钟，只给一个百分比
  /// 用户体验很差 —— 「还要多久」才是他真正关心的。
  Widget _buildProgress(ModelDownloadProgress p) {
    final failed = p.fatalError != null && !p.isCancelled;
    final color = p.isSuccess
        ? Colors.greenAccent
        : (failed ? Colors.redAccent : Colors.blue);

    final speed = p.speedLabel;
    final remaining = p.remainingLabel;
    // 右下角那一行：`已下载 / 总计 · 3.4MB/s · 约 4 分 12 秒`
    final metaParts = <String>[
      '${p.downloadedLabel} / ${p.totalLabel}',
      if (speed.isNotEmpty) speed,
      if (remaining.isNotEmpty) remaining,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                p.isCancelled
                    ? '已取消（已下载部分会保留）'
                    : (p.isFinished
                        ? (p.isSuccess ? '全部完成并通过校验' : '下载未完成')
                        : '正在下载 ${p.currentFileName ?? ''}'),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 百分比放最右：进度条动的时候这个数字一起跳，
            // 视觉上确认「真的在下载」而不是卡住了
            Text(
              '${p.percent}%',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            // 已结束但没有成功时（取消 / 失败），value 停在原地会让人以为
            // 还在跑。这里用 min(1.0) 保持原样更好 —— 停在哪就是哪，
            // 配合上面的「已取消」文案，语义是清楚的。
            value: p.fraction,
            minHeight: 6,
            backgroundColor: const Color(0xFF2A2A2A),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 6),
        // 速度 / 剩余时间 / 文件序号，一行放不下就换行
        Wrap(
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              metaParts.join(' · '),
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 10,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (p.fileCount > 0)
              Text(
                '文件 ${p.fileIndex}/${p.fileCount}',
                style: TextStyle(color: Colors.grey[700], fontSize: 10),
              ),
          ],
        ),
        if (p.fatalError != null) ...[
          const SizedBox(height: 6),
          Text(
            p.fatalError!,
            style: TextStyle(
              color: failed ? Colors.redAccent : Colors.grey[500],
              fontSize: 10,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  /// 目录设置卡片（自由路径）
  Widget _buildDirectoryCard() {
    final status = _status;
    final isCustom = status?.isCustomPath ?? false;
    final path = status?.directoryPath ?? '';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isCustom
              ? Colors.greenAccent.withValues(alpha: 0.3)
              : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCustom ? Icons.folder_special_rounded : Icons.folder_rounded,
                size: 18,
                color: isCustom ? Colors.greenAccent : Colors.blue[300],
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '模型目录',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _downloading ? null : _pickDirectory,
                icon: const Icon(Icons.edit_location_alt_rounded, size: 16),
                label: const Text('更改', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.blue[300],
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isCustom
                ? '正在使用自定义目录（重启后仍然生效）'
                : '默认存储在应用私有目录；也可以改成 SD 卡或 Download 下的任意文件夹。',
            style: TextStyle(color: Colors.grey[600], fontSize: 11, height: 1.6),
          ),
          if (path.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: _copyPath,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_open_rounded,
                      size: 16,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        path,
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

  /// 文件清单（按角色展示，兼容分语种命名）
  Widget _buildFileListCard() {
    final status = _status;

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
              Icon(Icons.description_rounded, size: 18, color: Colors.blue[300]),
              const SizedBox(width: 8),
              const Text(
                '已检测到的文件',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (status != null && !status.hasError)
                Text(
                  '${status.presentCount} 个',
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _buildRoleRow(
            role: 'encoder',
            label: '识别编码器',
            status: status,
          ),
          _buildRoleRow(
            role: 'decoder',
            label: '识别解码器',
            status: status,
          ),
          _buildRoleRow(
            role: 'joiner',
            label: '识别合并网络',
            status: status,
          ),
          _buildRoleRow(
            role: 'tokens',
            label: '识别词表',
            status: status,
          ),
          _buildRoleRow(
            role: ModelStorage.vadFileName,
            label: 'Silero VAD',
            status: status,
            optional: true,
          ),
          _buildRoleRow(
            role: '.gguf',
            label: '翻译模型',
            status: status,
          ),
          if (status != null && status.presentFiles.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
            const SizedBox(height: 10),
            Text(
              '实际文件',
              style: TextStyle(color: Colors.grey[600], fontSize: 10),
            ),
            const SizedBox(height: 4),
            ...status.presentFiles.map(
              (name) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '· $name',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRoleRow({
    required String role,
    required String label,
    required ModelStatus? status,
    bool optional = false,
  }) {
    bool exists;
    bool ready;

    if (role == ModelStorage.vadFileName) {
      exists = status?.vadReady ?? false;
      ready = exists;
    } else if (role == '.gguf') {
      exists = status?.mtReady ?? false;
      ready = exists;
    } else {
      exists = status?.presentFiles
              .any((name) => ModelStorage.matchRole(name, role)) ??
          false;
      ready = exists;
    }

    final color = ready
        ? Colors.greenAccent
        : (optional ? Colors.grey[600] : Colors.orangeAccent);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: ready ? Colors.white : Colors.grey[400],
                fontSize: 12,
              ),
            ),
          ),
          if (optional && !ready)
            Text(
              '可选',
              style: TextStyle(color: Colors.grey[700], fontSize: 9),
            ),
        ],
      ),
    );
  }

  /// 手动放置说明
  Widget _buildManualGuideCard() {
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
                '手动放入模型',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '如果你已经有现成的模型文件，直接把它们复制到上面的模型目录即可。'
            '文件名只要以 encoder / decoder / joiner / tokens 开头（扩展名 .onnx 或 .txt），'
            '翻译模型以 .gguf 结尾，都能被自动识别。\n\n'
            '用 ADB 推送时请替换 <包名> 与 <目录>：',
            style: TextStyle(color: Colors.grey[400], fontSize: 11, height: 1.7),
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
              'adb push encoder.onnx  <目录>/\n'
              'adb push decoder.onnx  <目录>/\n'
              'adb push joiner.onnx   <目录>/\n'
              'adb push tokens.txt    <目录>/\n'
              'adb push silero_vad.onnx <目录>/\n'
              'adb push *.gguf         <目录>/',
              style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 10,
                fontFamily: 'monospace',
                height: 1.7,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '放入后回到本页下拉刷新即可重新检测。',
            style: TextStyle(color: Colors.grey[600], fontSize: 10, height: 1.5),
          ),
        ],
      ),
    );
  }
}