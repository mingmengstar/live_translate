/// 首页
///
/// App 的第一屏，承载：
/// - 当前引擎状态（Mock / 真实引擎）
/// - 模型状态（缺失 / 已就绪）与「导入模型」入口
/// - 「进入翻译控制台」主入口（MainScreen 作为二级页）
library live_translate.ui.home_screen;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:live_translate/core/model/model_storage.dart';
import 'package:live_translate/core/service/translation_service.dart';
import 'package:live_translate/ui/main_screen.dart';
import 'package:live_translate/ui/model_import_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ModelStatus? _modelStatus;
  bool _checkingModels = true;

  @override
  void initState() {
    super.initState();
    _refreshModelStatus();
  }

  Future<void> _refreshModelStatus() async {
    if (mounted) setState(() => _checkingModels = true);
    final status = await ModelStorage.instance.inspect();
    if (!mounted) return;
    setState(() {
      _modelStatus = status;
      _checkingModels = false;
    });
  }

  Future<void> _openConsole() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
    if (mounted) await _refreshModelStatus();
  }

  Future<void> _openModelImport() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModelImportScreen()),
    );
    if (mounted) await _refreshModelStatus();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<TranslationService>();

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshModelStatus,
          color: Colors.blue,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              _buildBrandHeader(),
              const SizedBox(height: 24),
              _buildHeroCard(service),
              // 悬浮窗异常提示：必须放在首屏，而不是藏在控制台页。
              // 用户点「开始」后如果窗口没出来，第一眼就该看到原因，
              // 否则只会得到「不知道它在哪里」这种无从排查的反馈（BUG-2）。
              if (service.overlayNote != null) ...[
                const SizedBox(height: 16),
                _buildOverlayAlert(service),
              ],
              const SizedBox(height: 16),
              _buildModelCard(),
              const SizedBox(height: 16),
              _buildEngineCard(service),
              const SizedBox(height: 24),
              _buildPrimaryAction(service),
              const SizedBox(height: 12),
              _buildSecondaryAction(),
              const SizedBox(height: 20),
              _buildStatusFooter(service),
            ],
          ),
        ),
      ),
    );
  }

  /// 品牌标题
  Widget _buildBrandHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.blue.withValues(alpha: 0.35),
                Colors.greenAccent.withValues(alpha: 0.18),
              ],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
          ),
          child: const Icon(
            Icons.translate_rounded,
            color: Colors.blue,
            size: 30,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '实时翻译',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '系统内录 · 端侧实时字幕',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white10),
          ),
          child: Text(
            'v1.0.0',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  /// 首屏主视觉卡片
  Widget _buildHeroCard(TranslationService service) {
    final running = service.isServiceRunning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: running
              ? [
                  Colors.greenAccent.withValues(alpha: 0.16),
                  const Color(0xFF1E1E1E),
                ]
              : [
                  Colors.blue.withValues(alpha: 0.16),
                  const Color(0xFF1E1E1E),
                ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: (running ? Colors.greenAccent : Colors.blue)
              .withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: running ? Colors.greenAccent : Colors.grey[600],
                  boxShadow: running
                      ? [
                          BoxShadow(
                            color: Colors.greenAccent.withValues(alpha: 0.7),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                running ? '翻译服务运行中' : '翻译服务未启动',
                style: TextStyle(
                  color: running ? Colors.greenAccent : Colors.grey[300],
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '捕获手机正在播放的声音，实时生成双语字幕，'
            '并以悬浮窗显示在任意应用之上。',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 13,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTag('端侧离线', Icons.offline_bolt_rounded),
              _buildTag('悬浮字幕', Icons.subtitles_rounded),
              _buildTag('快捷磁贴', Icons.dashboard_customize_rounded),
            ],
          ),
        ],
      ),
    );
  }

  /// 悬浮窗异常提示条（首屏可见）
  ///
  /// ## 为什么必须有这一块（BUG-2）
  ///
  /// 真机复测时用户只说得出「点了开始没出现悬浮窗，不知道它在哪里」。
  /// 原因是失败信息此前只写在控制台页的「服务状态」卡片里 —— 而用户
  /// 点完开始往往就切到别的 App 了，根本不会再回来看这一行。
  ///
  /// 这里把三件事同时摆到首屏：
  /// 1. 一句话结论（[TranslationService.overlayNote]）；
  /// 2. 机器可读错误码（`PERMISSION` / `SERVICE_START` / `NOT_ATTACHED`），
  ///    便于用户直接把码报回来，无需翻 logcat；
  /// 3. 一个「重新显示」按钮，权限补授权后无需停止再启动。
  ///
  /// 错误码到人话的映射刻意放在 UI 层：`TranslationService` 只负责
  /// 透传 code，不该关心怎么措辞。
  Widget _buildOverlayAlert(TranslationService service) {
    final code = service.overlayErrorCode;
    final hint = _overlayCodeHint(code);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.layers_clear_rounded,
                size: 16,
                color: Colors.orangeAccent[200],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '悬浮字幕未显示',
                  style: TextStyle(
                    color: Colors.orangeAccent[200],
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (code != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    code,
                    style: TextStyle(
                      color: Colors.orangeAccent[100],
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            service.overlayNote!,
            style: TextStyle(
              color: Colors.grey[300],
              fontSize: 12,
              height: 1.6,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ],
          if (service.isServiceRunning) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  final result = await service.retryOverlay();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        result.ok
                            ? '悬浮窗已显示'
                            : '仍无法显示：${result.reason}',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重新显示', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.orangeAccent[200],
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 把悬浮窗错误码翻译成「用户下一步该做什么」
  ///
  /// 只覆盖悬浮窗结果里已知的几个错误码；未知码返回 null，
  /// 让 `overlayNote` 的原文承担说明职责。
  static String? _overlayCodeHint(String? code) {
    switch (code) {
      case 'PERMISSION':
        return '请到「设置 → 应用 → 实时翻译 → 显示在其他应用上层」开启权限后，'
            '回来点上面的「重新显示」。';
      case 'SERVICE_START':
        return '悬浮窗服务被系统拒绝启动。常见原因是应用刚切到后台触发了'
            '后台启动限制，请把 App 切回前台再点「重新显示」。';
      case 'NOT_ATTACHED':
        return '窗口服务起来了但没有挂到屏幕上。通常是权限被系统临时收回，'
            '请确认悬浮窗权限处于开启状态后重试。';
      case 'IN_FLIGHT':
        return '上一次显示还在进行中，稍等一秒再试。';
      case 'NOT_RUNNING':
        return '翻译服务未运行，先在控制台点开始。';
      default:
        return null;
    }
  }

  Widget _buildTag(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.grey[500]),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  /// 模型状态卡片
  Widget _buildModelCard() {
    final status = _modelStatus;
    final ready = status?.isReady ?? false;

    final Color accent;
    final String stateText;
    final String detail;
    final IconData icon;

    if (_checkingModels) {
      accent = Colors.grey;
      stateText = '检测中';
      detail = '正在扫描模型目录…';
      icon = Icons.hourglass_empty_rounded;
    } else if (status == null || status.hasError) {
      accent = Colors.orangeAccent;
      stateText = '无法检测';
      detail = '模型状态未知，点击进入查看详情';
      icon = Icons.help_outline_rounded;
    } else if (ready) {
      accent = Colors.greenAccent;
      stateText = '已就绪';
      detail = 'ASR 与 MT 模型均已检测到';
      icon = Icons.check_circle_rounded;
    } else {
      accent = Colors.orangeAccent;
      stateText = '缺失';
      detail = '已检测 ${status.presentCount}/${status.totalCount} 个文件，'
          '请到「模型管理」下载后才能开始翻译';
      icon = Icons.warning_amber_rounded;
    }

    return _buildCard(
      title: '模型状态',
      icon: Icons.inventory_2_rounded,
      trailing: TextButton(
        onPressed: _openModelImport,
        style: TextButton.styleFrom(
          foregroundColor: Colors.blue[300],
          textStyle: const TextStyle(fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: const Text('导入模型'),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stateText,
                  style: TextStyle(
                    color: accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 引擎状态卡片
  ///
  /// ## v0.5.0：不再有「Mock 模式」这个状态
  ///
  /// 现在只有两种真实状态：**已加载** / **未加载**。
  /// 「未加载」一定是模型没下好，正文里会说明缺什么，
  /// 而不是含糊地说「Mock 模式」让人以为功能正常。
  Widget _buildEngineCard(TranslationService service) {
    final manager = service.engineManager;
    final asrId = manager.currentASRId;
    final mtId = manager.currentMTId;
    // 两个都加载成功才算「就绪」：任一为 null 都说明模型不完整。
    final bothLoaded = asrId != null && mtId != null;

    return _buildCard(
      title: '引擎状态',
      icon: Icons.memory_rounded,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: (bothLoaded ? Colors.greenAccent : Colors.orangeAccent)
              .withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          bothLoaded ? '已加载' : '未加载',
          style: TextStyle(
            color: bothLoaded ? Colors.greenAccent : Colors.orangeAccent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      child: Column(
        children: [
          _buildInfoRow('ASR 引擎', manager.currentASR?.displayName ?? '未加载'),
          const SizedBox(height: 10),
          _buildInfoRow('MT 引擎', manager.currentMT?.displayName ?? '未加载'),
          const SizedBox(height: 10),
          // VAD 后端：Silero 模型缺失会静默降级为能量 VAD，
          // 这里显式暴露，避免用户困惑「为什么下载了模型切分还不准」。
          _buildInfoRow('VAD 后端', service.vadBackendNote ?? '未初始化'),
          const SizedBox(height: 10),
          // 引擎说明：模型缺失 / 加载失败时会说明具体原因
          _buildInfoRow('引擎说明', service.engineNote ?? '未初始化'),
          const SizedBox(height: 10),
          _buildInfoRow(
            '语言方向',
            '${service.mtSourceLang.toUpperCase()} → ${service.mtTargetLang.toUpperCase()}',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  /// 主行动按钮
  Widget _buildPrimaryAction(TranslationService service) {
    final running = service.isServiceRunning;
    return SizedBox(
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _openConsole,
        icon: Icon(
          running ? Icons.open_in_new_rounded : Icons.play_arrow_rounded,
          size: 22,
        ),
        label: Text(
          running ? '回到翻译控制台' : '进入翻译控制台',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  /// 次级入口
  Widget _buildSecondaryAction() {
    return SizedBox(
      height: 52,
      child: OutlinedButton.icon(
        onPressed: _openModelImport,
        icon: const Icon(Icons.file_download_outlined, size: 20),
        label: const Text('模型管理与导入', style: TextStyle(fontSize: 15)),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.grey[300],
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  /// 底部状态行
  Widget _buildStatusFooter(TranslationService service) {
    return Center(
      child: Column(
        children: [
          Text(
            service.statusMessage,
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            '下拉可刷新模型状态',
            style: TextStyle(color: Colors.grey[700], fontSize: 10),
          ),
        ],
      ),
    );
  }

  /// 通用卡片
  Widget _buildCard({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.blue[300], size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}