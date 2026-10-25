import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service managing the Android WifiManager.MulticastLock platform channel.
/// Ensures UDP broadcast packets can be transmitted and received on battery-optimized Android devices.
/// Safely no-ops on iOS, desktop, and test platforms without throwing exceptions.
class MulticastLockService {
  static const MethodChannel _channel = MethodChannel('com.fluxshare/multicast_lock');
  static int _refCount = 0;
  static bool _isHeld = false;

  static bool get isHeld => _isHeld;
  static int get refCount => _refCount;

  @visibleForTesting
  static void resetForTesting() {
    _refCount = 0;
    _isHeld = false;
  }

  /// Acquires MulticastLock if on Android. Reference counted.
  static Future<bool> acquire() async {
    _refCount++;
    if (!Platform.isAndroid) {
      _isHeld = true;
      return true;
    }

    if (_refCount == 1) {
      try {
        final success = await _channel.invokeMethod<bool>('acquireMulticastLock');
        _isHeld = success == true;
        debugPrint('[FluxShare-Network] [MulticastLock] Acquired native lock (refCount: $_refCount, success: $_isHeld)');
        return _isHeld;
      } catch (e) {
        debugPrint('[FluxShare-Network] [MulticastLock] Warning: Acquire failed or channel unsupported: $e');
        _isHeld = false;
        return false;
      }
    }
    return _isHeld;
  }

  /// Releases MulticastLock if currently held and reference count reaches 0.
  static Future<void> release() async {
    if (_refCount > 0) {
      _refCount--;
    }

    if (!Platform.isAndroid) {
      if (_refCount == 0) _isHeld = false;
      return;
    }

    if (_refCount == 0 && _isHeld) {
      try {
        await _channel.invokeMethod<bool>('releaseMulticastLock');
        debugPrint('[FluxShare-Network] [MulticastLock] Released native lock (refCount: 0)');
      } catch (e) {
        debugPrint('[FluxShare-Network] [MulticastLock] Warning: Release error: $e');
      } finally {
        _isHeld = false;
      }
    } else {
      debugPrint('[FluxShare-Network] [MulticastLock] Decremented refCount to $_refCount (lock held: $_isHeld)');
    }
  }

  /// Force releases all held locks regardless of reference count.
  static Future<void> forceReleaseAll() async {
    _refCount = 0;
    if (!Platform.isAndroid) {
      _isHeld = false;
      return;
    }
    try {
      await _channel.invokeMethod<bool>('releaseMulticastLock');
      debugPrint('[FluxShare-Network] [MulticastLock] Force released all locks');
    } catch (_) {
    } finally {
      _isHeld = false;
    }
  }
}
