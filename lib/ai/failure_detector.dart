import 'ai_models.dart';

/// Intelligent detector analyzing abnormal transfer anomalies and transport failures.
/// Detects sudden speed drops, burst chunk failures, checksum mismatches, and peer drops.
class AIFailureDetector {
  final List<double> _speedHistory = [];
  final List<String> _failureReasons = [];
  int _consecutiveFailures = 0;
  int _consecutiveChecksumFailures = 0;
  int _consecutiveTimeouts = 0;

  void reset() {
    _speedHistory.clear();
    _failureReasons.clear();
    _consecutiveFailures = 0;
    _consecutiveChecksumFailures = 0;
    _consecutiveTimeouts = 0;
  }

  /// Records successful chunk arrival and tracks throughput velocity.
  void recordChunkSuccess(double currentSpeedMbPerSec) {
    _consecutiveFailures = 0;
    _consecutiveChecksumFailures = 0;
    _consecutiveTimeouts = 0;

    _speedHistory.add(currentSpeedMbPerSec);
    if (_speedHistory.length > 10) {
      _speedHistory.removeAt(0);
    }
  }

  /// Records a chunk failure and analyzes failure classification.
  void recordChunkFailure(String reason) {
    _consecutiveFailures++;
    _failureReasons.add(reason);
    if (_failureReasons.length > 15) {
      _failureReasons.removeAt(0);
    }

    final lower = reason.toLowerCase();
    if (lower.contains('sha-256') || lower.contains('hash') || lower.contains('checksum')) {
      _consecutiveChecksumFailures++;
    } else if (lower.contains('timeout') || lower.contains('timed out')) {
      _consecutiveTimeouts++;
    }
  }

  /// Diagnoses current transfer health and returns recommendations if abnormal behavior is detected.
  AIFailureDiagnosis diagnose() {
    // 1. Check for SHA-256 / Checksum corruption
    if (_consecutiveChecksumFailures >= 2) {
      return AIFailureDiagnosis(
        issueDetected: true,
        severity: AIFailureSeverity.critical,
        explanation: '$_consecutiveChecksumFailures consecutive chunks failed SHA-256 cryptographic verification. '
            'Transport data corruption or disk write inconsistency detected.',
        recommendedAction: 'Reconnect to peer and re-verify chunk hash integrity.',
        actionType: AIFailureActionType.reconnect,
        recommendedChunkSize: 512 * 1024,
      );
    }

    // 2. Check for Consecutive Chunk Drop / Timeouts
    if (_consecutiveTimeouts >= 3 || _consecutiveFailures >= 4) {
      return AIFailureDiagnosis(
        issueDetected: true,
        severity: AIFailureSeverity.high,
        explanation: 'The peer connection appears unstable. $_consecutiveFailures consecutive chunk requests failed.',
        recommendedAction: 'Reduce chunk size to 512 KB and reduce parallel streams to stabilize transfer.',
        actionType: AIFailureActionType.reduceChunkSize,
        recommendedChunkSize: 512 * 1024,
        recommendedWorkers: 2,
      );
    }

    // 3. Check for Sudden Speed Drop
    if (_speedHistory.length >= 6) {
      final earlierWindow = _speedHistory.sublist(0, 3);
      final recentWindow = _speedHistory.sublist(_speedHistory.length - 3);

      final avgEarlier = earlierWindow.reduce((a, b) => a + b) / earlierWindow.length;
      final avgRecent = recentWindow.reduce((a, b) => a + b) / recentWindow.length;

      // Drop of more than 60% with earlier speed > 8 MB/s
      if (avgEarlier >= 8.0 && avgRecent < (avgEarlier * 0.4)) {
        return AIFailureDiagnosis(
          issueDetected: true,
          severity: AIFailureSeverity.medium,
          explanation: 'Transfer speed dropped significantly during the last chunks '
              'from ${avgEarlier.toStringAsFixed(1)} MB/s to ${avgRecent.toStringAsFixed(1)} MB/s.',
          recommendedAction: 'Reduce concurrent connections to prevent Wi-Fi channel contention.',
          actionType: AIFailureActionType.reduceParallel,
          recommendedWorkers: 2,
        );
      }
    }

    // 4. Check general failure log patterns
    if (_failureReasons.length >= 5) {
      final timeoutCount = _failureReasons.where((r) => r.toLowerCase().contains('timeout')).length;
      if (timeoutCount >= 4) {
        return const AIFailureDiagnosis(
          issueDetected: true,
          severity: AIFailureSeverity.high,
          explanation: 'Frequent network timeouts detected communicating with sender peer.',
          recommendedAction: 'Increase request timeout and resume transfer.',
          actionType: AIFailureActionType.resume,
        );
      }
    }

    return AIFailureDiagnosis.normal;
  }
}
