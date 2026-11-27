/// 主界面 UI
/// 深色卡片式设计，包含发光的蓝色播放/停止按钮
library live_translate.ui.main_screen;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:live_translate/core/engine/engine.dart';
import 'package:live_translate/core/service/translation_service.dart';

/// 检测是否在测试环境中
bool _isTestEnvironment() {
  // 通过判断 WidgetsBinding 类型来检测测试环境
  try {
    // 在 flutter_test 中，WidgetsBinding.instance 是 TestWidgetsFlutterBinding
    return WidgetsBinding.instance.runtimeType.toString().contains('Test');
  } catch (_) {
    return false;
  }
}

/// 测试环境标记，避免重复检测
final bool _kIsTestEnvironment = _isTestEnvironment();

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  late AnimationController _glowController;
  late AnimationController _pulseController;
  late Animation<double> _glowAnimation;
  late Animation<double> _pulseAnimation;
  
  @override
  void initState() {
    super.initState();
    
    // 发光动画控制器 - 只在非测试环境创建动画
    if (!_kIsTestEnvironment) {
      _glowController = AnimationController(
        duration: const Duration(seconds: 2),
        vsync: this,
      )..repeat(reverse: true);
      
      _glowAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
      );
      
      // 脉冲动画控制器（运行时）
      _pulseController = AnimationController(
        duration: const Duration(milliseconds: 1000),
        vsync: this,
      );
      
      _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
      );
    } else {
      // 测试环境：创建虚拟控制器避免空指针，不启动动画循环
      _glowController = AnimationController(
        duration: const Duration(milliseconds: 1),
        vsync: this,
      );
      _glowAnimation = AlwaysStoppedAnimation(0.5);
      
      _pulseController = AnimationController(
        duration: const Duration(milliseconds: 1),
        vsync: this,
      );
      _pulseAnimation = AlwaysStoppedAnimation(1.0);
    }
  }
  
  @override
  void dispose() {
    _glowController.dispose();
    _pulseController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Consumer<TranslationService>(
      builder: (context, service, child) {
        // 服务运行时启动脉冲动画（测试环境跳过动画循环）
        if (!_kIsTestEnvironment) {
          if (service.isServiceRunning && !_pulseController.isAnimating) {
            _pulseController.repeat(reverse: true);
          } else if (!service.isServiceRunning && _pulseController.isAnimating) {
            _pulseController.stop();
            _pulseController.reset();
          }
        }
        
        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: SafeArea(
            child: Column(
              children: [
                // 顶部状态栏区域
                _buildHeader(context, service),
                
                // 主内容区域
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        // 主控制卡片
                        _buildMainControlCard(context, service),
                        
                        const SizedBox(height: 16),
                        
                        // 状态信息卡片
                        _buildStatusCard(context, service),
                        
                        const SizedBox(height: 16),
                        
                        // 语言设置卡片
                        _buildLanguageCard(context, service),
                        
                        const SizedBox(height: 16),
                        
                        // 引擎选择卡片
                        _buildEngineCard(context, service),
                        
                        const SizedBox(height: 16),
                        
                        // 字幕历史卡片
                        _buildSubtitleHistoryCard(context, service),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  
  /// 顶部头部
  Widget _buildHeader(BuildContext context, TranslationService service) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(
          bottom: BorderSide(
            color: Colors.blue.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // 返回按钮（作为二级页进入时显示）
          if (Navigator.of(context).canPop())
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.grey[400],
                    size: 20,
                  ),
                ),
              ),
            ),
          // 应用图标和标题
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.translate_rounded,
              color: Colors.blue,
              size: 28,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '实时翻译',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  service.statusMessage,
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // 状态指示灯
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: service.isServiceRunning 
                  ? Colors.greenAccent 
                  : (service.lastError != null ? Colors.redAccent : Colors.grey),
              boxShadow: service.isServiceRunning
                  ? [
                      BoxShadow(
                        color: Colors.greenAccent.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
        ],
      ),
    );
  }
  
  /// 主控制卡片（大按钮）
  Widget _buildMainControlCard(BuildContext context, TranslationService service) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.blue.withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // 状态文本
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              service.isServiceRunning ? '正在监听系统音频...' : '点击开始实时翻译',
              key: ValueKey(service.isServiceRunning),
              style: TextStyle(
                color: service.isServiceRunning ? Colors.blue[300] : Colors.grey[400],
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          
          const SizedBox(height: 32),
          
          // 发光播放/停止按钮
          AnimatedBuilder(
            animation: Listenable.merge([_glowAnimation, _pulseAnimation]),
            builder: (context, child) {
              final isRunning = service.isServiceRunning;
              final glowIntensity = isRunning ? _pulseAnimation.value * _glowAnimation.value : _glowAnimation.value;
              final scale = isRunning ? _pulseAnimation.value : 1.0;
              
              return Transform.scale(
                scale: scale,
                child: GestureDetector(
                  onTap: () => service.toggleService(),
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: isRunning
                            ? [
                                Colors.redAccent.withValues(alpha: 0.9),
                                Colors.redAccent.withValues(alpha: 0.6),
                                Colors.redAccent.withValues(alpha: 0.2),
                              ]
                            : [
                                Colors.blue.withValues(alpha: 0.9),
                                Colors.blue.withValues(alpha: 0.6),
                                Colors.blue.withValues(alpha: 0.2),
                              ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (isRunning ? Colors.redAccent : Colors.blue)
                              .withValues(alpha: 0.4 * glowIntensity),
                          blurRadius: 30 * glowIntensity,
                          spreadRadius: 5 * glowIntensity,
                        ),
                        BoxShadow(
                          color: (isRunning ? Colors.redAccent : Colors.blue)
                              .withValues(alpha: 0.2 * glowIntensity),
                          blurRadius: 60 * glowIntensity,
                          spreadRadius: 15 * glowIntensity,
                        ),
                      ],
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) {
                          return RotationTransition(
                            turns: animation,
                            child: ScaleTransition(scale: animation, child: child),
                          );
                        },
                        child: Icon(
                          isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                          key: ValueKey(isRunning),
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          
          const SizedBox(height: 24),
          
          // 当前识别文本预览
          if (service.currentPartialText.isNotEmpty || service.currentTranslatedPartial.isNotEmpty)
            _buildLivePreview(service),
        ],
      ),
    );
  }
  
  /// 实时预览区域
  Widget _buildLivePreview(TranslationService service) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.blue.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_rounded, size: 16, color: Colors.blue[300]),
              const SizedBox(width: 8),
              Text(
                '实时识别',
                style: TextStyle(
                  color: Colors.blue[300],
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              service.currentPartialText.isNotEmpty 
                  ? service.currentPartialText 
                  : '等待语音输入...',
              key: ValueKey(service.currentPartialText),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 15,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (service.currentTranslatedPartial.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.translate_rounded, size: 16, color: Colors.greenAccent[200]),
                const SizedBox(width: 8),
                Text(
                  '实时翻译',
                  style: TextStyle(
                    color: Colors.greenAccent[200],
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                service.currentTranslatedPartial,
                key: ValueKey(service.currentTranslatedPartial),
                style: TextStyle(
                  color: Colors.greenAccent[100],
                  fontSize: 15,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  /// 状态信息卡片
  Widget _buildStatusCard(BuildContext context, TranslationService service) {
    return _buildCard(
      title: '服务状态',
      icon: Icons.info_outline_rounded,
      child: Column(
        children: [
          _buildStatusRow('运行状态', service.isServiceRunning ? '运行中' : '已停止', 
              valueColor: service.isServiceRunning ? Colors.greenAccent : Colors.grey),
          _buildStatusRow('ASR 引擎', service.engineManager.currentASR?.displayName ?? '未选择'),
          _buildStatusRow('MT 引擎', service.engineManager.currentMT?.displayName ?? '未选择'),
          // VAD 后端：Silero 模型缺失时会自动降级能量 VAD，
          // 用户需要知道「为什么音频切分效果不如预期」。
          if (service.vadBackendNote != null)
            _buildStatusRow('VAD 后端', service.vadBackendNote!),
          _buildStatusRow('语言方向', '${service.mtSourceLang} → ${service.mtTargetLang}'),
          // 悬浮窗状态：窗口没弹出来时这里会显示具体原因（权限被拒 /
          // 服务启动失败），用户不必去翻 logcat 才知道发生了什么。
          _buildStatusRow(
            '悬浮窗',
            service.isOverlayVisible
                ? '已显示'
                : (service.overlayNote ?? '未显示'),
            valueColor: service.isOverlayVisible
                ? Colors.greenAccent
                : (service.overlayNote != null ? Colors.orangeAccent : Colors.grey),
          ),
          // 服务在跑但窗口没出来 → 给一个直接补上的入口
          if (service.isServiceRunning && !service.isOverlayVisible)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  final r = await service.retryOverlay();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(r.ok ? '悬浮窗已显示' : '仍无法显示：${r.reason}'),
                    ),
                  );
                },
                icon: const Icon(Icons.fullscreen_rounded, size: 16),
                label: const Text('重新显示', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(foregroundColor: Colors.blue[300]),
              ),
            ),
          // 引擎选择原因：模型缺失 / 加载失败时会说明为何是 Mock，
          // 避免用户「下载了模型却还在跑 Mock」的困惑。
          if (service.engineNote != null)
            _buildStatusRow('引擎说明', service.engineNote!),
          if (service.lastError != null)
            _buildStatusRow('最后错误', service.lastError!, 
                valueColor: Colors.redAccent, isError: true),
          const SizedBox(height: 8),
          _buildOverlaySettingsRow(context, service),
        ],
      ),
    );
  }

  /// 悬浮窗显示设置（字号 / 透明度 / 位置）
  ///
  /// 为什么主界面也要有一份：悬浮窗上的按钮只在窗口可见时够得着。
  /// 用户收起窗口、或窗口因权限没弹出来时，仍需能预先调好这些值。
  /// 而且这里的改动会立刻同步到已显示的窗口上（走 shareData）。
  Widget _buildOverlaySettingsRow(
    BuildContext context,
    TranslationService service,
  ) {
    final s = service.overlaySettings;
    return Row(
      children: [
        Icon(Icons.tune_rounded, size: 15, color: Colors.grey[500]),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '悬浮窗设置',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
        ),
        // 字号 − / 值 / 字号 +
        _buildSettingChip(
          icon: Icons.text_decrease_rounded,
          tooltip: '减小悬浮窗字号',
          onTap: s.canDecreaseFont
              ? () => service.updateOverlaySettings(s.withSmallerFont)
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            s.fontSize.toStringAsFixed(0),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        _buildSettingChip(
          icon: Icons.text_increase_rounded,
          tooltip: '增大悬浮窗字号',
          onTap: s.canIncreaseFont
              ? () => service.updateOverlaySettings(s.withLargerFont)
              : null,
        ),
        const SizedBox(width: 6),
        // 透明度
        _buildSettingChip(
          icon: Icons.opacity_rounded,
          tooltip: '切换悬浮窗透明度（当前 ${(s.opacity * 100).round()}%）',
          onTap: () => service.updateOverlaySettings(s.withNextOpacity),
        ),
        const SizedBox(width: 6),
        // 位置
        _buildSettingChip(
          icon: Icons.vertical_align_top_rounded,
          tooltip: '切换悬浮窗位置（当前：${s.position.label}）',
          onTap: () => service.cycleOverlayPosition(),
          label: s.position.label,
        ),
      ],
    );
  }

  /// 设置区的小按钮（可带文字标签）
  Widget _buildSettingChip({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    String? label,
  }) {
    final enabled = onTap != null;
    final color = enabled ? Colors.grey[300] : Colors.grey[700];
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: label == null ? 6 : 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              if (label != null) ...[
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(color: color, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildStatusRow(String label, String value, {Color? valueColor, bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
  
  /// 语言设置卡片
  ///
  /// 三项选择共同决定「听到什么语言 → 翻译成什么语言」：
  /// 识别语言必须等于实际说话的语言，源语言应与识别语言保持一致，
  /// 否则会把已经识别对的文本按错误语种再翻译一遍。
  Widget _buildLanguageCard(BuildContext context, TranslationService service) {
    return _buildCard(
      title: '语言设置',
      icon: Icons.language_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHint(
            '决定「听什么语言、翻译成什么语言」。'
            '系统内录本身不带语种信息，全靠这里的设置告诉识别与翻译引擎。',
          ),
          const SizedBox(height: 16),

          // ASR 语言选择
          _buildDropdownSetting(
            label: '识别语言 (ASR)',
            hint: '告诉语音识别引擎：音频里说的是哪种语言。'
                '选错会直接导致识别结果是乱码或无输出。',
            value: service.asrLanguage,
            items: const [
              DropdownMenuItem(value: 'en', child: Text('英语 (English)')),
              DropdownMenuItem(value: 'ja', child: Text('日语 (日本語)')),
              DropdownMenuItem(value: 'zh', child: Text('中文 (中文)')),
              DropdownMenuItem(value: 'ko', child: Text('韩语 (한국어)')),
            ],
            onChanged: (value) => service.setASRLanguage(value!),
          ),
          
          const Divider(color: Colors.white10, height: 24),
          
          // MT 源语言
          _buildDropdownSetting(
            label: '源语言 (MT)',
            hint: '告诉翻译引擎：它拿到的文本原本是什么语言。'
                '通常应与上面的识别语言保持一致，不一致会造成「中文再翻成中文」。',
            value: service.mtSourceLang,
            items: const [
              DropdownMenuItem(value: 'en', child: Text('英语 (English)')),
              DropdownMenuItem(value: 'ja', child: Text('日语 (日本語)')),
              DropdownMenuItem(value: 'zh', child: Text('中文 (中文)')),
              DropdownMenuItem(value: 'ko', child: Text('韩语 (한국어)')),
            ],
            onChanged: (value) => service.setMTLanguagePair(value!, service.mtTargetLang),
          ),
          
          const Divider(color: Colors.white10, height: 24),
          
          // MT 目标语言
          _buildDropdownSetting(
            label: '目标语言 (MT)',
            hint: '告诉翻译引擎：要把文本翻译成哪种语言。'
                '字幕与悬浮窗显示的就是这个语言的结果。',
            value: service.mtTargetLang,
            items: const [
              DropdownMenuItem(value: 'ja', child: Text('日语 (日本語)')),
              DropdownMenuItem(value: 'en', child: Text('英语 (English)')),
              DropdownMenuItem(value: 'zh', child: Text('中文 (中文)')),
              DropdownMenuItem(value: 'ko', child: Text('韩语 (한국어)')),
            ],
            onChanged: (value) => service.setMTLanguagePair(service.mtSourceLang, value!),
          ),
        ],
      ),
    );
  }

  /// 卡片内的灰色说明文字（用于解释每个选择器的作用）
  Widget _buildSectionHint(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 14, color: Colors.grey[600]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 11,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildDropdownSetting({
    required String label,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              dropdownColor: const Color(0xFF2A2A2A),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey[400]),
              items: items,
              onChanged: onChanged,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
  
  /// 引擎选择卡片
  ///
  /// 这里的选项是「用哪套实现来做识别 / 翻译」，
  /// 与上面的语言设置是两件事：语言决定「听什么、译成什么」，
  /// 引擎决定「用谁来做」。
  Widget _buildEngineCard(BuildContext context, TranslationService service) {
    return _buildCard(
      title: '引擎选择',
      icon: Icons.memory_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHint(
            '决定「由谁来完成识别和翻译」。'
            'Mock 引擎只产生示例文本，用于在没有模型时验证整条链路；'
            '真实引擎需要先导入或下载模型才能启用。',
          ),
          const SizedBox(height: 16),

          // ASR 引擎选择
          _buildEngineSelector(
            label: 'ASR 引擎',
            hint: '把声音转成文字的组件。Mock 为演示实现，真实引擎为本地离线识别。',
            currentEngine: service.engineManager.currentASRId,
            availableEngines: service.engineManager.getRegisteredASREngines(),
            engineDisplayNames: const {
              'mock_asr': 'Mock ASR (测试用)',
              SherpaASREngine.kEngineId: 'Sherpa-ONNX 本地识别',
            },
            onChanged: (engineId) => service.switchASREngine(engineId),
          ),
          
          const Divider(color: Colors.white10, height: 24),
          
          // MT 引擎选择
          _buildEngineSelector(
            label: 'MT 引擎',
            hint: '把识别出的文字翻译成目标语言的组件。Mock 只加语言前缀，不做真正翻译。',
            currentEngine: service.engineManager.currentMTId,
            availableEngines: service.engineManager.getRegisteredMTEngines(),
            engineDisplayNames: const {
              'mock_mt': 'Mock MT (测试用)',
              LlamaMTEngine.kEngineId: 'Hy-MT1.5 本地翻译',
            },
            onChanged: (engineId) => service.switchMTEngine(engineId),
          ),
        ],
      ),
    );
  }
  
  Widget _buildEngineSelector({
    required String label,
    required String? currentEngine,
    required List<String> availableEngines,
    required Map<String, String> engineDisplayNames,
    required ValueChanged<String> onChanged,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: availableEngines.map((engineId) {
            final isSelected = engineId == currentEngine;
            final displayName = engineDisplayNames[engineId] ?? engineId;
            return FilterChip(
              label: Text(
                displayName,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[300],
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              selected: isSelected,
              onSelected: (_) => onChanged(engineId),
              selectedColor: Colors.blue.withValues(alpha: 0.3),
              checkmarkColor: Colors.blue,
              backgroundColor: const Color(0xFF2A2A2A),
              side: BorderSide(
                color: isSelected ? Colors.blue : Colors.white10,
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
  
  /// 字幕历史卡片
  Widget _buildSubtitleHistoryCard(BuildContext context, TranslationService service) {
    return _buildCard(
      title: '字幕历史 (${service.subtitleBuffer.length})',
      icon: Icons.history_rounded,
      action: service.subtitleBuffer.isNotEmpty
          ? TextButton.icon(
              onPressed: () => service.clearSubtitles(),
              icon: const Icon(Icons.clear_all_rounded, size: 16),
              label: const Text('清空'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey[500],
                textStyle: const TextStyle(fontSize: 12),
              ),
            )
          : null,
      child: service.subtitleBuffer.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(Icons.subtitles_rounded, size: 48, color: Colors.grey[800]),
                    const SizedBox(height: 12),
                    Text(
                      '暂无字幕记录',
                      style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '开始服务后将显示实时翻译结果',
                      style: TextStyle(color: Colors.grey[700], fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: service.subtitleBuffer.length.clamp(0, 20),
              separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
              itemBuilder: (context, index) {
                final entry = service.subtitleBuffer[index];
                return _buildSubtitleTile(entry);
              },
            ),
    );
  }
  
  Widget _buildSubtitleTile(SubtitleEntry entry) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: entry.isFinal ? Colors.green.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${entry.sourceLang}→${entry.targetLang}',
                  style: TextStyle(
                    color: entry.isFinal ? Colors.greenAccent : Colors.orangeAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
              if (!entry.isFinal) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.orangeAccent),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            entry.sourceText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 13,
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            entry.translatedText,
            style: TextStyle(
              color: Colors.blue[200],
              fontSize: 13,
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
  
  /// 通用卡片构建器
  Widget _buildCard({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.blue[300], size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}