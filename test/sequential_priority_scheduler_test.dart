import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/scheduler/sequential_priority_scheduler.dart';

void main() {
  group('SequentialPriorityScheduler Tests', () {
    late SequentialPriorityScheduler scheduler;

    setUp(() {
      // Priority window size of 2 -> chunks 0 and 1
      scheduler = SequentialPriorityScheduler(
        priorityWindowSize: 2,
      );
    });

    test('Prioritizes earliest missing chunk in priority window', () {
      final peerA = PeerInfo(
        peerId: 'peerA',
        deviceName: 'Phone A',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0, 1, 2, 3, 4},
        connectionStatus: 'available',
      );

      final scheduled = scheduler.schedule(
        missingChunks: {1, 0, 4, 3},
        candidates: [peerA],
      );

      expect(scheduled, isNotNull);
      // Chunk 0 must be selected first because 0 < 1 in priority window
      expect(scheduled!.chunkId, equals(0));
      expect(scheduled.peer.peerId, equals('peerA'));
    });

    test('Selects next priority chunk when chunk 0 is already downloaded', () {
      final peerA = PeerInfo(
        peerId: 'peerA',
        deviceName: 'Phone A',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0, 1, 2, 3, 4},
        connectionStatus: 'available',
      );

      final scheduled = scheduler.schedule(
        missingChunks: {1, 2, 3, 4}, // chunk 0 is downloaded
        candidates: [peerA],
      );

      expect(scheduled, isNotNull);
      // Chunk 1 is the next in the priority window [0, 1]
      expect(scheduled!.chunkId, equals(1));
    });

    test('Falls back to remaining chunks when priority window chunks are complete', () {
      final peerA = PeerInfo(
        peerId: 'peerA',
        deviceName: 'Phone A',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {2, 3, 4},
        connectionStatus: 'available',
      );

      final scheduled = scheduler.schedule(
        missingChunks: {2, 3, 4},
        candidates: [peerA],
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.chunkId, equals(2));
    });

    test('Falls back when peer does not hold priority chunk but holds other chunks', () {
      final peerB = PeerInfo(
        peerId: 'peerB',
        deviceName: 'Phone B',
        platform: 'ios',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {5, 6}, // Does not have chunks 0 or 1
        connectionStatus: 'available',
      );

      final scheduled = scheduler.schedule(
        missingChunks: {0, 1, 5, 6},
        candidates: [peerB],
      );

      expect(scheduled, isNotNull);
      // Must not stall; should fall back to chunk 5
      expect(scheduled!.chunkId, equals(5));
    });

    test('Skips disconnected peers', () {
      final peerDisconnected = PeerInfo(
        peerId: 'peerDisc',
        deviceName: 'Offline Phone',
        platform: 'android',
        ip: '192.168.1.12',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0, 1},
        connectionStatus: 'disconnected',
      );

      final scheduled = scheduler.schedule(
        missingChunks: {0, 1},
        candidates: [peerDisconnected],
      );

      expect(scheduled, isNull);
    });

    test('Returns null when no missing chunks or no candidates', () {
      final peerA = PeerInfo(
        peerId: 'peerA',
        deviceName: 'Phone A',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8081,
        availableChunks: {0},
        connectionStatus: 'available',
      );

      expect(
        scheduler.schedule(missingChunks: {}, candidates: [peerA]),
        isNull,
      );
      expect(
        scheduler.schedule(missingChunks: {0}, candidates: []),
        isNull,
      );
    });
  });
}
