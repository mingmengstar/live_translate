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
          '当前使用 Mock 引擎';
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
  Widget _buildEngineCard(TranslationService service) {
    final manager = service.engineManager;
    final asrId = manager.currentASRId;
    final mtId = manager.currentMTId;
    final isMock = (asrId?.startsWith('mock') ?? true) &&
        (mtId?.startsWith('mock') ?? true);

    return _buildCard(
      title: '引擎状态',
      icon: Icons.memory_rounded,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: (isMock ? Colors.orangeAccent : Colors.greenAccent)
              .withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          isMock ? 'Mock 模式' : '真实引擎',
          style: TextStyle(
            color: isMock ? Colors.orangeAccent : Colors.greenAccent,
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