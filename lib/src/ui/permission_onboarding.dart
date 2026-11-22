import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/pipeline_service.dart';
import '../services/overlay_service.dart';

class PermissionOnboarding extends StatefulWidget {
  final PipelineService pipeline;
  
  const PermissionOnboarding({super.key, required this.pipeline});

  @override
  State<PermissionOnboarding> createState() => _PermissionOnboardingState();
}

class _PermissionOnboardingState extends State<PermissionOnboarding> {
  int _currentStep = 0;
  bool _isRequesting = false;

  final List<_PermissionStep> _steps = [
    _PermissionStep(
      title: '录音权限',
      description: '允许应用录制系统内部音频，用于语音识别',
      icon: Icons.mic,
      permissionType: 'recordAudio',
    ),
    _PermissionStep(
      title: '悬浮窗权限',
      description: '显示实时字幕悬浮窗，始终保持在最上层',
      icon: Icons.layers,
      permissionType: 'overlay',
    ),
    _PermissionStep(
      title: '通知权限',
      description: '前台服务运行时需要显示持续通知',
      icon: Icons.notifications,
      permissionType: 'notification',
    ),
    _PermissionStep(
      title: '屏幕投射权限',
      description: '捕获系统内部音频需要 MediaProjection 授权',
      icon: Icons.cast,
      permissionType: 'mediaProjection',
    ),
  ];

  Future<void> _requestPermission(int index) async {
    if (_isRequesting) return;
    setState(() => _isRequesting = true);

    final step = _steps[index];
    bool granted = false;

    try {
      switch (step.permissionType) {
        case 'recordAudio':
          granted = await widget.pipeline.audioCapture.requestRecordAudioPermission();
          break;
        case 'overlay':
          granted = await OverlayService.requestPermission() ?? false;
          break;
        case 'notification':
          granted = await widget.pipeline.audioCapture.requestNotificationPermission();
          break;
        case 'mediaProjection':
          // MediaProjection 需要特殊处理，通过 startCapture 触发
          granted = true; // 标记为已引导，实际授权在 start 时
          break;
      }
    } catch (e) {
      print('请求权限失败: $e');
    }

    if (mounted) {
      setState(() {
        _isRequesting = false;
        if (granted || step.permissionType == 'mediaProjection') {
          if (index < _steps.length - 1) {
            _currentStep = index + 1;
          } else {
            // 所有权限引导完成
            Navigator.of(context).pop(true);
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final step = _steps[_currentStep];

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // 进度指示器
              LinearProgressIndicator(
                value: (_currentStep + 1) / _steps.length,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 8),
              Text(
                '权限配置 ${_currentStep + 1} / ${_steps.length}',
                style: GoogleFonts.notoSansSc(fontSize: 14, color: Colors.grey[400]),
              ),
              const SizedBox(height: 40),
              
              // 图标
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  step.icon,
                  size: 48,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              
              // 标题
              Text(
                step.title,
                style: GoogleFonts.notoSansSc(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              
              // 描述
              Text(
                step.description,
                style: GoogleFonts.notoSansSc(
                  fontSize: 16,
                  color: Colors.grey[300],
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              
              // 状态指示
              if (step.permissionType == 'recordAudio' && appState.hasRecordAudioPermission)
                _buildStatusBadge('已授权', Colors.green)
              else if (step.permissionType == 'overlay' && appState.hasOverlayPermission)
                _buildStatusBadge('已授权', Colors.green)
              else if (step.permissionType == 'notification' && appState.hasNotificationPermission)
                _buildStatusBadge('已授权', Colors.green)
              else if (step.permissionType == 'mediaProjection' && appState.hasMediaProjectionPermission)
                _buildStatusBadge('已授权', Colors.green)
              else
                _buildStatusBadge('待授权', Colors.orange),
              const SizedBox(height: 32),
              
              // 操作按钮
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isRequesting ? null : () => _requestPermission(_currentStep),
                  icon: _isRequesting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: Text(
                    _isRequesting
                        ? '正在请求...'
                        : step.permissionType == 'mediaProjection'
                            ? '开始授权向导'
                            : '去授权',
                    style: GoogleFonts.notoSansSc(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              
              // 跳过按钮（仅非最后一步）
              if (_currentStep < _steps.length - 1)
                TextButton(
                  onPressed: () => setState(() => _currentStep++),
                  child: Text(
                    '暂时跳过',
                    style: GoogleFonts.notoSansSc(color: Colors.grey[400]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        text,
        style: GoogleFonts.notoSansSc(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PermissionStep {
  final String title;
  final String description;
  final IconData icon;
  final String permissionType;

  const _PermissionStep({
    required this.title,
    required this.description,
    required this.icon,
    required this.permissionType,
  });
}