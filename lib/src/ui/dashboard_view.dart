import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import '../models/app_state.dart';
import '../services/pipeline_service.dart';
import '../services/overlay_service.dart';
import 'permission_onboarding.dart';

class DashboardView extends StatefulWidget {
  final PipelineService pipeline;
  
  const DashboardView({super.key, required this.pipeline});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  bool _showPermissionOnboarding = false;
  Timer? _permissionPollTimer;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _startPermissionPolling();
  }

  @override
  void dispose() {
    _permissionPollTimer?.cancel();
    super.dispose();
  }

  void _startPermissionPolling() {
    // 每2秒轮询检查 Overlay 和 Notification 权限（这两个权限需要用户手动授权后返回）
    _permissionPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollOverlayAndNotificationPermissions();
    });
  }

  Future<void> _pollOverlayAndNotificationPermissions() async {
    try {
      final overlayGranted = await OverlayService.isPermissionGranted();
      final perms = await widget.pipeline.audioCapture.checkPermissions();
      
      if (mounted) {
        final state = context.read<AppState>();
        state.setPermissions(
          overlay: overlayGranted,
          notification: perms['notification'] ?? false,
        );
        
        // 如果之前显示引导页且现在所有权限都满足，关闭引导页
        if (_showPermissionOnboarding && overlayGranted && (perms['notification'] ?? false) && (perms['recordAudio'] ?? false)) {
          setState(() => _showPermissionOnboarding = false);
        }
      }
    } catch (e) {
      print('权限轮询错误: $e');
    }
  }

  Future<void> _checkPermissions() async {
    final perms = await widget.pipeline.audioCapture.checkPermissions();
    final overlayGranted = await OverlayService.isPermissionGranted();
    final state = context.read<AppState>();
    state.setPermissions(
      recordAudio: perms['recordAudio'] ?? false,
      overlay: overlayGranted,
      notification: perms['notification'] ?? false,
      mediaProjection: perms['mediaProjection'] ?? false,
    );
    
    final allGranted = (perms['recordAudio'] ?? false) && overlayGranted && (perms['notification'] ?? false);
    if (!allGranted && mounted) {
      setState(() => _showPermissionOnboarding = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (_showPermissionOnboarding) {
      return PermissionOnboarding(
        pipeline: widget.pipeline,
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App Bar
          SliverAppBar(
            expandedHeight: 120,
            floating: false,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                '实时同传',
                style: GoogleFonts.notoSansSc(fontWeight: FontWeight.w700),
              ),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.surfaceContainerHighest,
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(
                  state.serviceState == ServiceState.running 
                      ? Icons.stop_circle 
                      : Icons.play_circle,
                  size: 28,
                ),
                onPressed: () => _toggleService(state),
                tooltip: state.serviceState == ServiceState.running ? '停止' : '开始',
              ),
              IconButton(
                icon: Icon(
                  state.overlayVisible ? Icons.visibility : Icons.visibility_off,
                  size: 28,
                ),
                onPressed: () => _toggleOverlay(state),
                tooltip: state.overlayVisible ? '隐藏悬浮窗' : '显示悬浮窗',
              ),
            ],
          ),

          // 状态卡片
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _StatusCard(state: state),
                  const SizedBox(height: 16),
                  _DirectionCard(state: state, pipeline: widget.pipeline),
                  const SizedBox(height: 16),
                  _FontSizeCard(state: state, pipeline: widget.pipeline),
                  const SizedBox(height: 16),
                  _SubtitlePreviewCard(state: state),
                  const SizedBox(height: 16),
                  _PermissionStatusCard(state: state),
                  const SizedBox(height: 16),
                  _BottomActionBar(state: state, pipeline: widget.pipeline),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleService(AppState state) {
    if (state.serviceState == ServiceState.running) {
      widget.pipeline.stop();
    } else {
      // 需要 MediaProjection 权限，这里简化处理
      widget.pipeline.startWithPermission(0);
    }
  }

  void _toggleOverlay(AppState state) {
    if (state.overlayVisible) {
      widget.pipeline.hideOverlay();
    } else {
      widget.pipeline.showOverlay();
    }
  }
}

class _StatusCard extends StatelessWidget {
  final AppState state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = state.serviceState == ServiceState.running;
    final isStarting = state.serviceState == ServiceState.starting;
    final isError = state.serviceState == ServiceState.error;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (isRunning) {
      statusColor = Colors.green;
      statusText = '运行中';
      statusIcon = Icons.circle;
    } else if (isStarting) {
      statusColor = theme.colorScheme.primary;
      statusText = '启动中...';
      statusIcon = Icons.hourglass_empty;
    } else if (isError) {
      statusColor = Colors.red;
      statusText = '错误';
      statusIcon = Icons.error;
    } else {
      statusColor = theme.colorScheme.onSurface.withOpacity(0.5);
      statusText = '已停止';
      statusIcon = Icons.circle_outlined;
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(statusIcon, color: statusColor, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '服务状态',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // 语言方向指示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                state.languageDirection == LanguageDirection.en2ja ? 'EN → JA' : 'JA → EN',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectionCard extends StatelessWidget {
  final AppState state;
  final PipelineService pipeline;
  const _DirectionCard({required this.state, required this.pipeline});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '翻译方向',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _DirectionButton(
                    label: '英语 → 日语',
                    icon: Icons.translate,
                    isSelected: state.languageDirection == LanguageDirection.en2ja,
                    onTap: () => pipeline.changeLanguageDirection(LanguageDirection.en2ja),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DirectionButton(
                    label: '日语 → 英语',
                    icon: Icons.translate,
                    isSelected: state.languageDirection == LanguageDirection.ja2en,
                    onTap: () => pipeline.changeLanguageDirection(LanguageDirection.ja2en),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _DirectionButton({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline.withOpacity(0.2),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface.withOpacity(0.6),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FontSizeCard extends StatelessWidget {
  final AppState state;
  final PipelineService pipeline;
  const _FontSizeCard({required this.state, required this.pipeline});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '字幕字体大小',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                Text(
                  '${state.fontSize.toInt()}sp',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Slider(
              value: state.fontSize,
              min: 12,
              max: 32,
              divisions: 20,
              label: '${state.fontSize.toInt()}sp',
              onChanged: (value) {
                state.setFontSize(value);
                pipeline.overlay.updateSettings(fontSize: value);
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('小', style: theme.textTheme.bodySmall),
                Text('大', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubtitlePreviewCard extends StatelessWidget {
  final AppState state;
  const _SubtitlePreviewCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '字幕预览',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.lastOriginalText.isEmpty ? '原文将显示在这里...' : state.lastOriginalText,
                    style: GoogleFonts.notoSansSc(
                      color: Colors.white,
                      fontSize: state.fontSize,
                      height: 1.4,
                    ),
                  ),
                  if (state.lastTranslatedText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      height: 1,
                      color: Colors.white.withOpacity(0.3),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.lastTranslatedText,
                      style: GoogleFonts.notoSansSc(
                        color: Colors.greenAccent,
                        fontSize: state.fontSize,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionStatusCard extends StatelessWidget {
  final AppState state;
  const _PermissionStatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final permissions = [
      ('录音权限', Icons.mic, state.hasRecordAudioPermission),
      ('悬浮窗权限', Icons.window, state.hasOverlayPermission),
      ('通知权限', Icons.notifications, state.hasNotificationPermission),
      ('屏幕录制', Icons.screen_share, state.hasMediaProjectionPermission),
    ];

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '权限状态',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: permissions.map((p) => _PermissionChip(
                label: p.$1,
                icon: p.$2,
                granted: p.$3,
              )).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool granted;

  const _PermissionChip({
    required this.label,
    required this.icon,
    required this.granted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: granted ? Colors.green.withOpacity(0.1) : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: granted ? Colors.green : theme.colorScheme.outline.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: granted ? Colors.green : theme.colorScheme.onSurface.withOpacity(0.5),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: granted ? Colors.green : theme.colorScheme.onSurface.withOpacity(0.7),
              fontWeight: granted ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  final AppState state;
  final PipelineService pipeline;
  const _BottomActionBar({required this.state, required this.pipeline});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = state.serviceState == ServiceState.running;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: Icon(isRunning ? Icons.stop : Icons.play_arrow, size: 24),
                label: Text(
                  isRunning ? '停止翻译' : '开始翻译',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: () {
                  if (isRunning) {
                    pipeline.stop();
                  } else {
                    pipeline.startWithPermission(0);
                  }
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: isRunning ? Colors.red : theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(state.overlayVisible ? Icons.visibility_off : Icons.visibility, size: 24),
                label: Text(
                  state.overlayVisible ? '隐藏悬浮窗' : '显示悬浮窗',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: () {
                  if (state.overlayVisible) {
                    pipeline.hideOverlay();
                  } else {
                    pipeline.showOverlay();
                  }
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}