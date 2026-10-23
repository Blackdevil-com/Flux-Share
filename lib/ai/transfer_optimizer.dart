import 'dart:math';
import '../metrics/metrics_models.dart';
import 'ai_models.dart';

/// AI-assisted transfer optimization engine.
/// Evaluates non-sensitive transport metrics to recommend optimal chunk sizes,
/// worker concurrency, retry policies, and timeouts.
/// Safety rule: Never bypasses deterministic checks; requires user confirmation to apply.
class IntelligentTransferOptimizer {
  /// Evaluates current metrics and produces actionable tuning recommendations.
  AITransferOptimization recommendOptimization({
    required int fileSize,
    required double currentSpeedMbPerSec,
    required double avgLatencyMillis,
    required int completedChunks,
    required int retransmissionCount,
    int currentChunkSize = 1024 * 1024,
    int currentWorkers = 5,
  }) {
    final totalAttempts = max(1, completedChunks + retransmissionCount);
    final retryRate = retransmissionCount / totalAttempts;

    // High instability / congestion detected
    if (retryRate >= 0.08 || avgLatencyMillis >= 400 || (currentSpeedMbPerSec < 1.5 && completedChunks > 5)) {
      final targetChunkSize = 512 * 1024; // 512 KB
      final targetWorkers = 2;
      final retryPct = (retryRate * 100).toStringAsFixed(1);

      return AITransferOptimization(
        recommendedChunkSize: targetChunkSize,
        recommendedChunkSizeLabel: '512 KB',
        recommendedParallelWorkers: targetWorkers,
        retryStrategy: 'Exponential Backoff (100ms - 2s)',
        timeoutSeconds: 8,
        useParallel: true,
        reason: 'Elevated packet loss detected (retry rate: $retryPct%, latency: ${avgLatencyMillis.toStringAsFixed(0)}ms). '
            'Reducing chunk size from ${_formatBytes(currentChunkSize)} to 512 KB and concurrency to $targetWorkers '
            'minimizes retransmission penalties and stabilizes the connection.',
        confidence: 0.94,
        isApplied: false,
      );
    }

    // Moderate connection
    if (retryRate >= 0.03 || avgLatencyMillis >= 200) {
      final targetChunkSize = min(currentChunkSize, 2 * 1024 * 1024); // max 2 MB
      final targetWorkers = 3;

      return AITransferOptimization(
        recommendedChunkSize: targetChunkSize,
        recommendedChunkSizeLabel: _formatBytes(targetChunkSize),
        recommendedParallelWorkers: targetWorkers,
        retryStrategy: 'Adaptive backoff with peer rotation',
        timeoutSeconds: 6,
        useParallel: true,
        reason: 'Moderate latency variance observed. Setting concurrency to $targetWorkers '
            'with ${_formatBytes(targetChunkSize)} chunks balances throughput against buffer saturation.',
        confidence: 0.88,
        isApplied: false,
      );
    }

    // High performance, stable connection
    int optimalChunkSize;
    int optimalWorkers;

    if (fileSize > 500 * 1024 * 1024) {
      optimalChunkSize = 8 * 1024 * 1024; // 8 MB
      optimalWorkers = 6;
    } else if (fileSize > 100 * 1024 * 1024) {
      optimalChunkSize = 4 * 1024 * 1024; // 4 MB
      optimalWorkers = 5;
    } else {
      optimalChunkSize = 2 * 1024 * 1024; // 2 MB
      optimalWorkers = 4;
    }

    return AITransferOptimization(
      recommendedChunkSize: optimalChunkSize,
      recommendedChunkSizeLabel: _formatBytes(optimalChunkSize),
      recommendedParallelWorkers: optimalWorkers,
      retryStrategy: 'Immediate fast retry with peer failover',
      timeoutSeconds: 4,
      useParallel: true,
      reason: 'Stable local link detected (< 3% retries, ${avgLatencyMillis.toStringAsFixed(0)}ms latency). '
          'Allocating $optimalWorkers parallel streams with ${_formatBytes(optimalChunkSize)} chunks '
          'maximizes local Wi-Fi throughput.',
      confidence: 0.96,
      isApplied: false,
    );
  }

  /// Evaluates historic transfer sessions to advise next transfer parameters.
  AITransferOptimization recommendForNewTransfer({
    required int fileSize,
    List<TransferMetrics>? pastMetrics,
  }) {
    if (pastMetrics == null || pastMetrics.isEmpty) {
      // Default rule-based recommendation
      return recommendOptimization(
        fileSize: fileSize,
        currentSpeedMbPerSec: 10.0,
        avgLatencyMillis: 80.0,
        completedChunks: 10,
        retransmissionCount: 0,
      );
    }

    final recent = pastMetrics.take(5).toList();
    double totalSpeed = 0;
    int totalRetries = 0;
    int totalChunks = 0;
    double totalLatency = 0;

    for (final m in recent) {
      totalSpeed += m.aggregateThroughputMbps / 8.0; // convert Mbps to MB/s
      totalRetries += m.retransmissionCount;
      totalChunks += m.chunkCount;
      totalLatency += m.avgTimeToFirstByteMillis;
    }

    final avgSpeed = totalSpeed / recent.length;
    final avgLatency = totalLatency / recent.length;

    return recommendOptimization(
      fileSize: fileSize,
      currentSpeedMbPerSec: avgSpeed,
      avgLatencyMillis: avgLatency > 0 ? avgLatency : 90.0,
      completedChunks: totalChunks,
      retransmissionCount: totalRetries,
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}
