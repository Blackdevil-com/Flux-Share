import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/transfer/peer_concurrency_manager.dart';

void main() {
  group('PeerConcurrencyManager Tests (AIMD & Cooldown)', () {
    late PeerConcurrencyManager manager;

    setUp(() {
      manager = PeerConcurrencyManager(
        minConcurrency: 1,
        maxConcurrency: 8,
        failureCooldownThreshold: 3,
        cooldownDuration: const Duration(seconds: 10),
      );
    });

    test('Initial allowed concurrency starts at 2', () {
      expect(manager.getAllowedConcurrency('peer_1'), equals(2));
      expect(manager.canRequestFrom('peer_1'), isTrue);
    });

    test('Additive Increase raises concurrency after consecutive successes', () {
      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');

      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');

      // Concurrency increases from 2 to 3
      expect(manager.getAllowedConcurrency('peer_1'), equals(3));
    });

    test('Multiplicative Decrease cuts concurrency in half on failure', () {
      // Raise to 4 first
      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');
      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');
      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');
      manager.markRequestStarted('peer_1');
      manager.markRequestSuccess('peer_1');

      expect(manager.getAllowedConcurrency('peer_1'), equals(4));

      // Failure occurs
      manager.markRequestStarted('peer_1');
      manager.markRequestFailure('peer_1');

      // 4 ~/ 2 = 2
      expect(manager.getAllowedConcurrency('peer_1'), equals(2));
    });

    test('Three consecutive failures trigger peer cooldown', () {
      manager.markRequestStarted('peer_1');
      manager.markRequestFailure('peer_1');

      manager.markRequestStarted('peer_1');
      manager.markRequestFailure('peer_1');

      manager.markRequestStarted('peer_1');
      manager.markRequestFailure('peer_1');

      expect(manager.canRequestFrom('peer_1'), isFalse);

      final peer = PeerInfo(
        peerId: 'peer_1',
        deviceName: 'Phone 1',
        platform: 'android',
        ip: '192.168.1.10',
        httpPort: 8080,
        webSocketPort: 8080,
      );

      final available = manager.filterAvailableCandidates([peer]);
      expect(available, isEmpty);
    });

    test('Saturated peer with inFlight == allowedConcurrency cannot accept more', () {
      // Allowed is 2
      manager.markRequestStarted('peer_1');
      manager.markRequestStarted('peer_1');

      expect(manager.canRequestFrom('peer_1'), isFalse);

      // Once one finishes, can request again
      manager.markRequestSuccess('peer_1');
      expect(manager.canRequestFrom('peer_1'), isTrue);
    });
  });
}
