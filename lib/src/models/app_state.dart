import 'package:flutter/material.dart';

enum LanguageDirection { en2ja, ja2en }

enum ServiceState { stopped, starting, running, stopping, error }

class AppState extends ChangeNotifier {
  ServiceState _serviceState = ServiceState.stopped;
  LanguageDirection _languageDirection = LanguageDirection.en2ja;
  double _fontSize = 18.0;
  bool _overlayVisible = false;
  String _lastOriginalText = '';
  String _lastTranslatedText = '';
  
  // 权限标志
  bool _hasRecordAudioPermission = false;
  bool _hasOverlayPermission = false;
  bool _hasNotificationPermission = false;
  bool _hasMediaProjectionPermission = false;

  ServiceState get serviceState => _serviceState;
  LanguageDirection get languageDirection => _languageDirection;
  double get fontSize => _fontSize;
  bool get overlayVisible => _overlayVisible;
  String get lastOriginalText => _lastOriginalText;
  String get lastTranslatedText => _lastTranslatedText;
  bool get hasRecordAudioPermission => _hasRecordAudioPermission;
  bool get hasOverlayPermission => _hasOverlayPermission;
  bool get hasNotificationPermission => _hasNotificationPermission;
  bool get hasMediaProjectionPermission => _hasMediaProjectionPermission;

  void setServiceState(ServiceState state) {
    _serviceState = state;
    notifyListeners();
  }

  void setLanguageDirection(LanguageDirection direction) {
    _languageDirection = direction;
    notifyListeners();
  }

  void setFontSize(double size) {
    _fontSize = size.clamp(12.0, 32.0);
    notifyListeners();
  }

  void setOverlayVisible(bool visible) {
    _overlayVisible = visible;
    notifyListeners();
  }

  void updateSubtitle(String original, String translated) {
    _lastOriginalText = original;
    _lastTranslatedText = translated;
    notifyListeners();
  }

  void setPermissions({
    bool? recordAudio,
    bool? overlay,
    bool? notification,
    bool? mediaProjection,
  }) {
    if (recordAudio != null) _hasRecordAudioPermission = recordAudio;
    if (overlay != null) _hasOverlayPermission = overlay;
    if (notification != null) _hasNotificationPermission = notification;
    if (mediaProjection != null) _hasMediaProjectionPermission = mediaProjection;
    notifyListeners();
  }
}