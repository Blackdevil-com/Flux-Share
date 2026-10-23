import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/scheduler/ucb1_adaptive_scheduler.dart';

void main() {
  group('UCB1AdaptiveScheduler Tests', () {
    late UCB1AdaptiveScheduler scheduler;

    setUp(() {
      scheduler = UCB1AdaptiveScheduler(explorationConstant: 1.0);
    });

    test('Explores unseen peers first before exploiting known peers', () {
      final peerA = PeerInfo(
        peerId: 'peerA',
        deviceName: 'Fast Peer',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0, 1},
        connectionStatus: 'available',
      );
      final peerB = PeerInfo(
        peerId: 'peerB',
        deviceName: 'Unseen Peer',
        platform: 'android',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0, 1},
        connectionStatus: 'available',
      );

      // Record 5 successful trials for peerA
      for (int i = 0; i < 5; i++) {
        scheduler.recordTransferResult(
          peerId: 'peerA',
          chunkId: i,
          success: true,
          bytesTransferred: 1024 * 1024,
          duration: const Duration(milliseconds: 50),
        );
      }

      // peerB has 0 trials; UCB1 must assign +infinity score to peerB
      final scheduled = scheduler.schedule(
        missingChunks: {0, 1},
        candidates: [peerA, peerB],
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.peer.peerId, equals('peerB'));
    });

    test('Favors higher throughput peer when both have been sampled', () {
      final fastPeer = PeerInfo(
        peerId: 'fastPeer',
        deviceName: 'Fast Peer',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0},
        connectionStatus: 'available',
      );
      final slowPeer = PeerInfo(
        peerId: 'slowPeer',
        deviceName: 'Slow Peer',
        platform: 'ios',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0},
        connectionStatus: 'available',
      );

      // Fast peer: 10 MB/s (1MB in 100ms)
      scheduler.recordTransferResult(
        peerId: 'fastPeer',
        chunkId: 0,
        success: true,
        bytesTransferred: 1024 * 1024,
        duration: const Duration(milliseconds: 100),
      );

      // Slow peer: 1 MB/s (1MB in 1000ms)
      scheduler.recordTransferResult(
        peerId: 'slowPeer',
        chunkId: 0,
        success: true,
        bytesTransferred: 1024 * 1024,
        duration: const Duration(milliseconds: 1000),
      );

      final scheduled = scheduler.schedule(
        missingChunks: {0},
        candidates: [fastPeer, slowPeer],
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.peer.peerId, equals('fastPeer'));
    });

    test('Penalizes failing peer and reroutes to healthier peer', () {
      final healthyPeer = PeerInfo(
        peerId: 'healthyPeer',
        deviceName: 'Healthy Peer',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {1},
        connectionStatus: 'available',
      );
      final failingPeer = PeerInfo(
        peerId: 'failingPeer',
        deviceName: 'Failing Peer',
        platform: 'ios',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {1},
        connectionStatus: 'available',
      );

      // Sample both peers once so exploitation phase begins
      scheduler.recordTransferResult(
        peerId: 'healthyPeer',
        chunkId: 0,
        success: true,
        bytesTransferred: 1024 * 1024,
        duration: const Duration(milliseconds: 200),
      );

      scheduler.recordTransferResult(
        peerId: 'failingPeer',
        chunkId: 0,
        success: false,
        bytesTransferred: 0,
        duration: const Duration(milliseconds: 500),
      );

      final scheduled = scheduler.schedule(
        missingChunks: {1},
        candidates: [healthyPeer, failingPeer],
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.peer.peerId, equals('healthyPeer'));
    });

    test('Skips disconnected peers regardless of past reward', () {
      final offlinePeer = PeerInfo(
        peerId: 'offlinePeer',
        deviceName: 'Offline Fast Peer',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0},
        connectionStatus: 'disconnected',
      );

      scheduler.recordTransferResult(
        peerId: 'offlinePeer',
        chunkId: 0,
        success: true,
        bytesTransferred: 50 * 1024 * 1024,
        duration: const Duration(milliseconds: 10),
      );

      final scheduled = scheduler.schedule(
        missingChunks: {0},
        candidates: [offlinePeer],
      );

      expect(scheduled, isNull);
    });
  });
}
