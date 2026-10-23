import 'dart:collection';

class _ProgressSample {
  final DateTime timestamp;
  final int totalBytes;

  _ProgressSample({required this.timestamp, required this.totalBytes});
}

/// Computes a live rolling throughput speed window and smoothed ETA.
/// Eliminates the latency drag of cumulative division and prevents ETA jitter.
class TransferMetricsCalculator {
  final Duration windowDuration;
  final double smoothingAlpha;

  final Queue<_ProgressSample> _samples = Queue<_ProgressSample>();
  double _smoothedSpeedMbPerSec = 0.0;
  DateTime _lastSampleTime = DateTime.now();

  TransferMetricsCalculator({
    this.windowDuration = const Duration(milliseconds: 2500),
    this.smoothingAlpha = 0.35,
  });

  double get smoothedSpeedMbPerSec => _smoothedSpeedMbPerSec;

  /// Records the latest total bytes transferred and returns the updated metrics.
  ({double currentSpeedMbPerSec, double smoothedSpeedMbPerSec, int remainingSeconds}) update({
    required int totalBytesTransferred,
    required int totalFileSize,
  }) {
    final now = DateTime.now();
    _lastSampleTime = now;

    // Add current sample
    _samples.addLast(_ProgressSample(timestamp: now, totalBytes: totalBytesTransferred));

    // Purge samples older than the rolling window
    final cutoff = now.subtract(windowDuration);
    while (_samples.length > 2 && _samples.first.timestamp.isBefore(cutoff)) {
      _samples.removeFirst();
    }

    double instantSpeed = 0.0;
    if (_samples.length >= 2) {
      final oldest = _samples.first;
      final newest = _samples.last;
      final elapsedMs = newest.timestamp.difference(oldest.timestamp).inMilliseconds;
      final bytesDelta = newest.totalBytes - oldest.totalBytes;

      if (elapsedMs > 100 && bytesDelta >= 0) {
        // Speed in MB/s: (bytes / (1024 * 1024)) / (ms / 1000)
        instantSpeed = (bytesDelta / (1024 * 1024)) / (elapsedMs / 1000.0);
      }
    }

    // Exponential moving average for smooth display
    if (_smoothedSpeedMbPerSec == 0.0) {
      _smoothedSpeedMbPerSec = instantSpeed;
    } else {
      _smoothedSpeedMbPerSec = (smoothingAlpha * instantSpeed) +
          ((1.0 - smoothingAlpha) * _smoothedSpeedMbPerSec);
    }

    // Clamp speed to non-negative
    if (_smoothedSpeedMbPerSec < 0.01) {
      _smoothedSpeedMbPerSec = 0.0;
    }

    // Calculate remaining seconds based on smoothed speed
    int remainingSeconds = 0;
    final remainingBytes = totalFileSize - totalBytesTransferred;
    if (remainingBytes > 0 && _smoothedSpeedMbPerSec > 0.05) {
      final bytesPerSec = _smoothedSpeedMbPerSec * 1024 * 1024;
      remainingSeconds = (remainingBytes / bytesPerSec).ceil();
    }

    return (
      currentSpeedMbPerSec: instantSpeed,
      smoothedSpeedMbPerSec: _smoothedSpeedMbPerSec,
      remainingSeconds: remainingSeconds,
    );
  }

  /// Checks if transfer has stalled (no bytes received recently)
  bool isStalled({Duration stallThreshold = const Duration(seconds: 3)}) {
    return DateTime.now().difference(_lastSampleTime) > stallThreshold;
  }

  /// Resets the calculator metrics
  void reset() {
    _samples.clear();
    _smoothedSpeedMbPerSec = 0.0;
    _lastSampleTime = DateTime.now();
  }
}
