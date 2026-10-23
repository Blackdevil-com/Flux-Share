import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/metrics/metrics_collector.dart';

void main() {
  group('MetricsCollector Tests', () {
    late MetricsCollector collector;

    setUp(() {
      collector = MetricsCollector();
    });

    test('Differentiates sender upload volume from cooperative forwarding volume', () async {
      collector.startTransfer(
        transferId: 'transfer_123',
        fileId: 'file_123',
        fileName: 'test_file.bin',
        fileSize: 4000,
        chunkCount: 4,
        chunkSize: 1000,
        coordinatorPeerId: 'coordinator_peer',
        receiverCount: 2,
        schedulerMode: 'round-robin',
      );

      // Coordinator served 1000 bytes
      collector.recordChunkDelivered(
        sourcePeerId: 'coordinator_peer',
        receiverPeerId: 'receiver_1',
        bytes: 1000,
      );

      // Peer 1 cooperatively forwarded 1000 bytes to Peer 2
      collector.recordChunkDelivered(
        sourcePeerId: 'receiver_1',
        receiverPeerId: 'receiver_2',
        bytes: 1000,
      );

      collector.recordRetransmission();

      final metrics = await collector.finalizeTransfer();
      expect(metrics, isNotNull);
      expect(metrics!.senderUploadVolumeBytes, equals(1000));
      expect(metrics.cooperativeForwardingVolumeBytes, equals(1000));
      expect(metrics.cooperativeRatio, closeTo(0.5, 0.001));
      expect(metrics.retransmissionCount, equals(1));
      expect(metrics.fileSize, equals(4000));
    });

    test('Captures TTFB, peer concurrency history, and retry events (Part 8)', () async {
      collector.startTransfer(
        transferId: 'transfer_456',
        fileId: 'file_456',
        fileName: 'video.mp4',
        fileSize: 8000,
        chunkCount: 2,
        chunkSize: 4000,
        coordinatorPeerId: 'host_peer',
        receiverCount: 1,
        schedulerMode: 'round-robin',
      );

      collector.recordTimeToFirstByte(0, 18); // 18ms
      collector.recordTimeToFirstByte(1, 24); // 24ms

      collector.recordPeerConcurrency('host_peer', 2);
      collector.recordPeerConcurrency('host_peer', 3);

      collector.recordRetryEvent(
        chunkId: 0,
        failedPeerId: 'host_peer',
        retriedPeerId: 'peer_2',
        reason: 'HTTP 500',
      );

      final metrics = await collector.finalizeTransfer();
      expect(metrics, isNotNull);
      expect(metrics!.timeToFirstByteMillis[0], equals(18));
      expect(metrics.timeToFirstByteMillis[1], equals(24));
      expect(metrics.avgTimeToFirstByteMillis, equals(21.0));
      expect(metrics.peerConcurrencyHistory['host_peer'], equals([2, 3]));
      expect(metrics.retryEvents.length, equals(1));
      expect(metrics.retryEvents.first.failedPeerId, equals('host_peer'));
      expect(metrics.retryEvents.first.retriedPeerId, equals('peer_2'));
    });
  });
}
