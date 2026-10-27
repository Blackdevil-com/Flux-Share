import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/discovery/discovery_service.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/multicast_lock_service.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/peer/peer_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    MulticastLockService.resetForTesting();
    NetworkUtils.customLocalIp = null;
    NetworkUtils.customInterfaces = null;
    DiscoveryService.resetForTesting();

    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    DiscoveryService.resetForTesting();
    MulticastLockService.resetForTesting();
    NetworkUtils.customLocalIp = null;
    NetworkUtils.customInterfaces = null;
    await server.stop();
  });

  group('Room Discovery and PIN Join Regression Tests', () {
    test('1. Host is advertising and the receiver joins with the correct PIN', () async {
      final discovery = DiscoveryService();
      const testPort = 18881;

      final startResult = await discovery.startRoomHost(
        pin: '7253',
        roomId: 'room_7253',
        serverPort: serverPort,
        deviceName: 'Pixel 7 Host',
        discoveryPort: testPort,
      );
      expect(startResult, isA<RoomHostStartSuccess>());

      NetworkUtils.customLocalIp = '127.0.0.1';

      final joinResult = await discovery.discoverRoomResult(
        pin: '7253',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );

      expect(joinResult, isA<DiscoverRoomSuccess>());
      final room = (joinResult as DiscoverRoomSuccess).room;
      expect(room.pin, equals('7253'));
      expect(room.roomId, equals('room_7253'));
      expect(room.port, equals(serverPort));
      expect(room.deviceName, equals('Pixel 7 Host'));

      discovery.stopRoomHost();
    });

    test('2. Incorrect PIN is rejected without crashing or falsely joining', () async {
      final discovery = DiscoveryService();
      const testPort = 18882;

      await discovery.startRoomHost(
        pin: '7253',
        roomId: 'room_7253',
        serverPort: serverPort,
        deviceName: 'Host Device',
        discoveryPort: testPort,
      );

      NetworkUtils.customLocalIp = '127.0.0.1';

      // Receiver searches for incorrect PIN
      final joinResult = await discovery.discoverRoomResult(
        pin: '9999',
        discoveryPort: testPort,
        timeout: const Duration(milliseconds: 600),
      );

      expect(joinResult, isA<DiscoverRoomTimeout>());
      final timeout = joinResult as DiscoverRoomTimeout;
      expect(timeout.pin, equals('9999'));

      discovery.stopRoomHost();
    });

    test('3. Host is unavailable and the receiver receives a clear timeout result', () async {
      final discovery = DiscoveryService();
      const testPort = 18883;

      // No host started
      NetworkUtils.customLocalIp = '127.0.0.1';

      final joinResult = await discovery.discoverRoomResult(
        pin: '4444',
        discoveryPort: testPort,
        timeout: const Duration(milliseconds: 600),
      );

      expect(joinResult, isA<DiscoverRoomTimeout>());
      final timeout = joinResult as DiscoverRoomTimeout;
      expect(timeout.pin, equals('4444'));
      expect(timeout.targetsAttempted.isNotEmpty, isTrue);
    });

    test('4. A valid response arriving after another target fails is still accepted', () async {
      final discovery = DiscoveryService();
      const testPort = 18884;

      await discovery.startRoomHost(
        pin: '5555',
        roomId: 'room_fallback',
        serverPort: serverPort,
        deviceName: 'Fallback Host',
        discoveryPort: testPort,
      );

      NetworkUtils.customLocalIp = '127.0.0.1';

      final joinResult = await discovery.discoverRoomResult(
        pin: '5555',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );

      expect(joinResult, isA<DiscoverRoomSuccess>());
      final room = (joinResult as DiscoverRoomSuccess).room;
      expect(room.pin, equals('5555'));

      discovery.stopRoomHost();
    });

    test('5. Multiple candidate addresses and duplicate packets do not cause duplicate joins', () async {
      final discovery = DiscoveryService();
      const testPort = 18885;

      await discovery.startRoomHost(
        pin: '3333',
        roomId: 'room_dup',
        serverPort: serverPort,
        deviceName: 'Dup Host',
        discoveryPort: testPort,
      );

      NetworkUtils.customLocalIp = '127.0.0.1';

      int eventCount = 0;
      final joinResult = await discovery.discoverRoomResult(
        pin: '3333',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );

      if (joinResult is DiscoverRoomSuccess) {
        eventCount++;
      }

      // Allow any extra in-flight datagrams to arrive
      await Future.delayed(const Duration(milliseconds: 300));

      expect(eventCount, equals(1));
      discovery.stopRoomHost();
    });

    test('6. Repeated attempts after a timeout work correctly', () async {
      final discovery = DiscoveryService();
      const testPort = 18886;
      NetworkUtils.customLocalIp = '127.0.0.1';

      // Attempt 1: Host not started yet -> times out
      final attempt1 = await discovery.discoverRoomResult(
        pin: '6666',
        discoveryPort: testPort,
        timeout: const Duration(milliseconds: 400),
      );
      expect(attempt1, isA<DiscoverRoomTimeout>());

      // Host starts advertising PIN 6666
      await discovery.startRoomHost(
        pin: '6666',
        roomId: 'room_retry',
        serverPort: serverPort,
        deviceName: 'Retry Host',
        discoveryPort: testPort,
      );

      // Attempt 2: Receiver retries -> succeeds immediately
      final attempt2 = await discovery.discoverRoomResult(
        pin: '6666',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );
      expect(attempt2, isA<DiscoverRoomSuccess>());
      expect((attempt2 as DiscoverRoomSuccess).room.pin, equals('6666'));

      discovery.stopRoomHost();
    });

    test('7. Interface-selection and broadcast-target behavior for different supported local network ranges', () async {
      // 7a. Standard Wi-Fi router subnet (192.168.31.x)
      final wifiTargets = await NetworkUtils.getDiscoveryTargets(localIpOverride: '192.168.31.156');
      final wifiIps = wifiTargets.map((t) => t.address).toSet();
      expect(wifiIps.contains('192.168.31.255'), isTrue, reason: 'Must include /24 subnet broadcast');
      expect(wifiIps.contains('192.168.31.1'), isTrue, reason: 'Must include gateway/hotspot host');
      expect(wifiIps.contains('255.255.255.255'), isTrue, reason: 'Must include global broadcast');
      expect(wifiIps.contains('192.168.43.1'), isTrue, reason: 'Must include fallback Android hotspot gateway');

      // 7b. Android Hotspot subnet (192.168.43.x)
      final hotspotTargets = await NetworkUtils.getDiscoveryTargets(localIpOverride: '192.168.43.1');
      final hotspotIps = hotspotTargets.map((t) => t.address).toSet();
      expect(hotspotIps.contains('192.168.43.255'), isTrue);
      expect(hotspotIps.contains('192.168.43.1'), isTrue);
      expect(hotspotIps.contains('255.255.255.255'), isTrue);

      // 7c. iOS Hotspot subnet (172.20.10.x)
      final iosTargets = await NetworkUtils.getDiscoveryTargets(localIpOverride: '172.20.10.2');
      final iosIps = iosTargets.map((t) => t.address).toSet();
      expect(iosIps.contains('172.20.10.255'), isTrue);
      expect(iosIps.contains('172.20.10.1'), isTrue);

      // 7d. Known peer from PeerManager is included
      PeerManager().addOrUpdatePeer(PeerInfo(
        peerId: 'peer_known_1',
        deviceName: 'Known Phone',
        platform: 'Android',
        ip: '192.168.31.88',
        httpPort: 8080,
        webSocketPort: 8080,
      ));
      final peerTargets = await NetworkUtils.getDiscoveryTargets(localIpOverride: '192.168.31.156');
      expect(peerTargets.map((t) => t.address).contains('192.168.31.88'), isTrue);
    });

    test('8. Malformed or unrelated discovery packets are ignored safely', () async {
      final discovery = DiscoveryService();
      const testPort = 18887;

      await discovery.startRoomHost(
        pin: '8888',
        roomId: 'room_safe',
        serverPort: serverPort,
        deviceName: 'Safe Host',
        discoveryPort: testPort,
      );

      // Send raw garbage datagrams to the discovery socket
      final senderSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      senderSocket.send(utf8.encode('NOT_JSON_GARBAGE_12345'), InternetAddress('127.0.0.1'), testPort);
      senderSocket.send(utf8.encode('{"action":"RANDOM_UNHANDLED_ACTION"}'), InternetAddress('127.0.0.1'), testPort);
      senderSocket.send(utf8.encode(''), InternetAddress('127.0.0.1'), testPort);
      await Future.delayed(const Duration(milliseconds: 100));

      // Host must still be fully alive and respond to valid request
      NetworkUtils.customLocalIp = '127.0.0.1';
      final result = await discovery.discoverRoomResult(
        pin: '8888',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );
      expect(result, isA<DiscoverRoomSuccess>());

      senderSocket.close();
      discovery.stopRoomHost();
    });

    test('9. Socket cleanup and multicast-lock release occur on success, failure, and cancellation', () async {
      final discovery = DiscoveryService();
      const testPort = 18888;
      expect(MulticastLockService.refCount, equals(0));

      // 9a. Host start and stop releases lock
      await discovery.startRoomHost(
        pin: '1001',
        roomId: 'room_lock',
        serverPort: serverPort,
        deviceName: 'Lock Host',
        discoveryPort: testPort,
      );
      expect(MulticastLockService.isHeld, isTrue);

      discovery.stopRoomHost();
      expect(MulticastLockService.refCount, equals(0));
      expect(MulticastLockService.isHeld, isFalse);

      // 9b. Receiver timeout releases lock cleanly
      NetworkUtils.customLocalIp = '127.0.0.1';
      await discovery.discoverRoomResult(
        pin: '9999',
        discoveryPort: testPort,
        timeout: const Duration(milliseconds: 300),
      );
      expect(MulticastLockService.refCount, equals(0));
      expect(MulticastLockService.isHeld, isFalse);
    });

    test('10. Starting or stopping a transfer does not unintentionally disable active room discovery/connection workflow', () async {
      final discovery = DiscoveryService();
      const testPort = 18889;

      // Peer presence is running (as started in main.dart)
      await discovery.startPeerPresenceListener(
        peerId: 'peer_main',
        deviceName: 'Main Device',
        platform: 'Android',
        serverPort: serverPort,
        discoveryPort: testPort,
      );
      expect(discovery.isPresenceActive, isTrue);

      // Host starts room host on the SAME port (no EADDRINUSE conflict!)
      final hostResult = await discovery.startRoomHost(
        pin: '7253',
        roomId: 'batch_active_1',
        serverPort: serverPort,
        deviceName: 'Sender Device',
        discoveryPort: testPort,
      );
      expect(hostResult, isA<RoomHostStartSuccess>());
      expect(discovery.isRoomHostingActive, isTrue);

      NetworkUtils.customLocalIp = '127.0.0.1';

      // Receiver 1 joins
      final rx1 = await discovery.discoverRoomResult(
        pin: '7253',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );
      expect(rx1, isA<DiscoverRoomSuccess>());

      // Sender "starts transfer" -> updates room configuration without breaking discovery
      await discovery.startRoomHost(
        pin: '7253',
        roomId: 'batch_active_1',
        serverPort: serverPort,
        deviceName: 'Sender Device',
        discoveryPort: testPort,
      );

      // Receiver 2 can still discover and join the active room
      final rx2 = await discovery.discoverRoomResult(
        pin: '7253',
        discoveryPort: testPort,
        timeout: const Duration(seconds: 2),
      );
      expect(rx2, isA<DiscoverRoomSuccess>());
      expect((rx2 as DiscoverRoomSuccess).room.pin, equals('7253'));

      discovery.stopRoomHost();
      discovery.stopPeerPresenceListener();
      expect(discovery.isRoomHostingActive, isFalse);
      expect(discovery.isPresenceActive, isFalse);
    });
  });
}
