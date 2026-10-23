import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/scheduler/round_robin_scheduler.dart';

void main() {
  group('RoundRobinScheduler Tests', () {
    late RoundRobinScheduler scheduler;

    setUp(() {
      scheduler = RoundRobinScheduler();
    });

    test('Returns null when no candidates or no missing chunks', () {
      expect(scheduler.selectSource({}, []), isNull);
      expect(
        scheduler.selectSource(
          {0, 1},
          [],
        ),
        isNull,
      );
    });

    test('Selects candidate holding at least one missing chunk', () {
      final peer1 = PeerInfo(
        peerId: 'p1',
        deviceName: 'Phone 1',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0, 1},
      );
      final peer2 = PeerInfo(
        peerId: 'p2',
        deviceName: 'Phone 2',
        platform: 'android',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {2, 3},
      );

      final selected1 = scheduler.selectSource({2, 3}, [peer1, peer2]);
      expect(selected1?.peerId, equals('p2'));

      final selected2 = scheduler.selectSource({0}, [peer1, peer2]);
      expect(selected2?.peerId, equals('p1'));
    });

    test('Rotates sequentially through candidates in round-robin fashion', () {
      final peer1 = PeerInfo(
        peerId: 'p1',
        deviceName: 'Phone 1',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0, 1, 2},
      );
      final peer2 = PeerInfo(
        peerId: 'p2',
        deviceName: 'Phone 2',
        platform: 'android',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0, 1, 2},
      );

      final first = scheduler.selectSource({0, 1, 2}, [peer1, peer2]);
      final second = scheduler.selectSource({0, 1, 2}, [peer1, peer2]);

      expect(first?.peerId, equals('p1'));
      expect(second?.peerId, equals('p2'));
    });

    test('Skips disconnected peers', () {
      final peer1 = PeerInfo(
        peerId: 'p1',
        deviceName: 'Phone 1',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0},
        connectionStatus: 'disconnected',
      );
      final peer2 = PeerInfo(
        peerId: 'p2',
        deviceName: 'Phone 2',
        platform: 'android',
        ip: '192.168.1.11',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0},
      );

      final selected = scheduler.selectSource({0}, [peer1, peer2]);
      expect(selected?.peerId, equals('p2'));
    });
  });
}
