import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/ai/ai_models.dart';
import 'package:fluxshare/ai/failure_detector.dart';
import 'package:fluxshare/ai/transfer_optimizer.dart';

void main() {
  group('AI Transfer Optimizer & Failure Detection Tests (Requirements 3 & 4)', () {
    late IntelligentTransferOptimizer optimizer;
    late AIFailureDetector failureDetector;

    setUp(() {
      optimizer = IntelligentTransferOptimizer();
      failureDetector = AIFailureDetector();
    });

    test('Recommends larger chunks and high parallel concurrency for stable connection', () {
      final rec = optimizer.recommendOptimization(
        fileSize: 4 * 1024 * 1024 * 1024, // 4 GB (Ubuntu.iso)
        currentSpeedMbPerSec: 35.0,
        avgLatencyMillis: 45.0,
        completedChunks: 100,
        retransmissionCount: 1, // 1% retry rate
        currentChunkSize: 1024 * 1024,
      );

      expect(rec.useParallel, isTrue);
      expect(rec.recommendedChunkSize, greaterThanOrEqualTo(4 * 1024 * 1024)); // 4MB - 8MB
      expect(rec.recommendedParallelWorkers, greaterThanOrEqualTo(5));
      expect(rec.confidence, greaterThanOrEqualTo(0.90));
      expect(rec.reason, contains('Stable local link'));
    });

    test('Recommends smaller chunks and reduced concurrency for unstable/lossy connection', () {
      final rec = optimizer.recommendOptimization(
        fileSize: 500 * 1024 * 1024,
        currentSpeedMbPerSec: 1.2,
        avgLatencyMillis: 480.0,
        completedChunks: 20,
        retransmissionCount: 5, // 20% retry rate
        currentChunkSize: 4 * 1024 * 1024,
      );

      expect(rec.recommendedChunkSize, equals(512 * 1024)); // 512 KB
      expect(rec.recommendedParallelWorkers, lessThanOrEqualTo(3));
      expect(rec.reason, contains('Elevated packet loss'));
    });

    test('Failure detector flags repeated SHA-256 integrity verification errors', () {
      failureDetector.recordChunkFailure('Chunk SHA-256 mismatch: expected abc, got xyz');
      failureDetector.recordChunkFailure('Chunk SHA-256 mismatch: expected 123, got 456');

      final diagnosis = failureDetector.diagnose();
      expect(diagnosis.issueDetected, isTrue);
      expect(diagnosis.severity, equals(AIFailureSeverity.critical));
      expect(diagnosis.explanation, contains('SHA-256 cryptographic verification'));
      expect(diagnosis.actionType, equals(AIFailureActionType.reconnect));
    });

    test('Failure detector flags consecutive chunk drop and timeouts', () {
      failureDetector.recordChunkFailure('Connection timed out connecting to 192.168.1.5');
      failureDetector.recordChunkFailure('Peer 192.168.1.5 failed to send response headers');
      failureDetector.recordChunkFailure('Connection timed out connecting to 192.168.1.5');
      failureDetector.recordChunkFailure('Connection timed out connecting to 192.168.1.5');

      final diagnosis = failureDetector.diagnose();
      expect(diagnosis.issueDetected, isTrue);
      expect(diagnosis.severity, equals(AIFailureSeverity.high));
      expect(diagnosis.explanation, contains('connection appears unstable'));
      expect(diagnosis.actionType, equals(AIFailureActionType.reduceChunkSize));
    });

    test('Failure detector flags sudden speed drops', () {
      // Simulate fast speeds then sudden collapse
      failureDetector.recordChunkSuccess(25.0);
      failureDetector.recordChunkSuccess(24.0);
      failureDetector.recordChunkSuccess(26.0);
      failureDetector.recordChunkSuccess(2.0);
      failureDetector.recordChunkSuccess(1.8);
      failureDetector.recordChunkSuccess(1.5);

      final diagnosis = failureDetector.diagnose();
      expect(diagnosis.issueDetected, isTrue);
      expect(diagnosis.explanation, contains('Transfer speed dropped significantly'));
      expect(diagnosis.actionType, equals(AIFailureActionType.reduceParallel));
    });

    test('Failure detector returns normal status for healthy transfers', () {
      failureDetector.recordChunkSuccess(15.0);
      failureDetector.recordChunkSuccess(16.0);
      failureDetector.recordChunkSuccess(17.0);

      final diagnosis = failureDetector.diagnose();
      expect(diagnosis.issueDetected, isFalse);
      expect(diagnosis.explanation, contains('performing normally'));
    });
  });
}
