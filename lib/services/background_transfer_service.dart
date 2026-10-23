import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform bridge for managing the Android Foreground Service, WakeLock,
/// and ongoing notification during background file transfers.
/// Safe no-op on non-Android platforms or during unit tests.
class BackgroundTransferService {
  static const MethodChannel _channel =
      MethodChannel('com.example.fluxshare/background_service');

  static final BackgroundTransferService _instance =
      BackgroundTransferService._internal();

  factory BackgroundTransferService() => _instance;
  static BackgroundTransferService get instance => _instance;

  final List<VoidCallback> _cancelListeners = [];
  bool _isRunning = false;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  BackgroundTransferService._internal() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  bool get isRunning => _isRunning;

  /// Register a callback to be invoked when the user taps "Cancel" on the notification.
  void addCancelListener(VoidCallback listener) {
    if (!_cancelListeners.contains(listener)) {
      _cancelListeners.add(listener);
    }
  }

  /// Remove a cancel callback.
  void removeCancelListener(VoidCallback listener) {
    _cancelListeners.remove(listener);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onNotificationCancel') {
      debugPrint('[BackgroundTransferService] Cancel action received from notification');
      for (final listener in List<VoidCallback>.from(_cancelListeners)) {
        try {
          listener();
        } catch (e) {
          debugPrint('[BackgroundTransferService] Listener error: $e');
        }
      }
    }
  }

  /// Starts the Android foreground service with a persistent ongoing notification and partial wake lock.
  Future<bool> startForeground({
    required String title,
    required String message,
    int progress = 0,
    int maxProgress = 100,
  }) async {
    if (!Platform.isAndroid) return true;

    try {
      final success = await _channel.invokeMethod<bool>('startForegroundService', {
        'title': title,
        'message': message,
        'progress': progress,
        'maxProgress': maxProgress,
      });
      _isRunning = success ?? false;
      return _isRunning;
    } on MissingPluginException {
      debugPrint('[BackgroundTransferService] Channel not implemented on this platform');
      return false;
    } catch (e) {
      debugPrint('[BackgroundTransferService] Error starting foreground service: $e');
      return false;
    }
  }

  /// Updates the foreground notification with current progress, speed, and ETA.
  /// Automatically throttles updates to avoid flooding Android's NotificationManager.
  Future<void> updateProgress({
    required String title,
    required String message,
    required int progress,
    int maxProgress = 100,
    bool force = false,
  }) async {
    if (!Platform.isAndroid || !_isRunning) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastUpdate).inMilliseconds < 450) {
      return;
    }
    _lastUpdate = now;

    try {
      await _channel.invokeMethod<bool>('updateNotification', {
        'title': title,
        'message': message,
        'progress': progress,
        'maxProgress': maxProgress,
      });
    } catch (e) {
      debugPrint('[BackgroundTransferService] Error updating notification: $e');
    }
  }

  /// Stops the Android foreground service and releases all WakeLocks.
  Future<bool> stopForeground() async {
    if (!Platform.isAndroid) return true;
    _isRunning = false;

    try {
      final success =
          await _channel.invokeMethod<bool>('stopForegroundService');
      return success ?? true;
    } catch (e) {
      debugPrint('[BackgroundTransferService] Error stopping foreground service: $e');
      return false;
    }
  }
}
