import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

class AudioCaptureService {
  static const MethodChannel _methodChannel = MethodChannel('live_translate/permission');
  static const EventChannel _pcmChannel = EventChannel('live_translate/audio_pcm');
  static const EventChannel _eventChannel = EventChannel('live_translate/audio_event');

  Stream<Uint8List>? _pcmStream;
  Stream<Map<String, dynamic>>? _eventStream;

  Stream<Uint8List> get pcmStream {
    _pcmStream ??= _pcmChannel.receiveBroadcastStream().cast<Uint8List>();
    return _pcmStream!;
  }

  Stream<Map<String, dynamic>> get eventStream {
    _eventStream ??= _eventChannel.receiveBroadcastStream().cast<Map<String, dynamic>>();
    return _eventStream!;
  }

  Future<void> initialize() async {
    // 无需额外初始化，原生服务已在 onCreate 中建立通道
  }

  Future<bool> startCapture({required int mediaProjectionPermission}) async {
    try {
      final result = await _methodChannel.invokeMethod('requestMediaProjection');
      return result == true;
    } on PlatformException catch (e) {
      print('AudioCaptureService startCapture error: ${e.message}');
      return false;
    }
  }

  Future<void> stopCapture() async {
    // 由原生服务自动停止，或通过 stopService 实现
  }

  Future<void> setLanguageDirection(String direction) async {
    try {
      await _methodChannel.invokeMethod('setLanguageDirection', {'direction': direction});
    } on PlatformException catch (e) {
      print('AudioCaptureService setLanguageDirection error: ${e.message}');
    }
  }

  // 权限请求方法
  Future<bool> requestRecordAudioPermission() async {
    try {
      final result = await _methodChannel.invokeMethod('requestRecordAudioPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestOverlayPermission() async {
    try {
      final result = await _methodChannel.invokeMethod('requestOverlayPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      final result = await _methodChannel.invokeMethod('requestNotificationPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, bool>> checkPermissions() async {
    try {
      final result = await _methodChannel.invokeMethod('checkPermissions');
      return Map<String, bool>.from(result as Map);
    } on PlatformException {
      return {
        'recordAudio': false,
        'overlay': false,
        'notification': false,
        'mediaProjection': false,
      };
    }
  }
}