import 'dart:io';
import 'package:flutter/services.dart';

/// Service managing the Android WifiManager.MulticastLock platform channel.
/// Ensures UDP broadcast packets can be transmitted and received on battery-optimized Android devices.
/// Safely no-ops on iOS and desktop platforms without throwing exceptions.
class MulticastLockService {
  static const MethodChannel _channel = MethodChannel('com.fluxshare/multicast_lock');
  static bool _isHeld = false;

  static bool get isHeld => _isHeld;

  /// Acquires MulticastLock if on Android.
  static Future<bool> acquire() async {
    if (!Platform.isAndroid || _isHeld) return false;
    try {
      final success = await _channel.invokeMethod<bool>('acquireMulticastLock');
      if (success == true) {
        _isHeld = true;
        return true;
      }
    } catch (_) {
      // Platform channel unsupported in test or desktop environment
    }
    return false;
  }

  /// Releases MulticastLock if currently held.
  static Future<void> release() async {
    if (!Platform.isAndroid || !_isHeld) return;
    try {
      await _channel.invokeMethod<bool>('releaseMulticastLock');
    } catch (_) {
    } finally {
      _isHeld = false;
    }
  }
}
