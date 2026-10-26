import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/discovery/discovery_service.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/network/http_client.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/multicast_lock_service.dart';
import 'package:fluxshare/network/network_utils.dart';

class _FakeNetworkInterface implements NetworkInterface {
  @override
  final String name;
  @override
  final int index;
  @override
  final List<InternetAddress> addresses;

  _FakeNetworkInterface({
    required this.name,
    required this.index,
    required this.addresses,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    MulticastLockService.resetForTesting();
    NetworkUtils.customLocalIp = null;
    NetworkUtils.customInterfaces = null;
    DiscoveryService.customSocketBinder = null;

    tempDir = await Directory.systemTemp.createTemp('fluxshare_hotspot_conn_test_');
    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    DiscoveryService.customSocketBinder = null;
    NetworkUtils.customLocalIp = null;
    NetworkUtils.customInterfaces = null;
    await server.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Hotspot Room Discovery & Receiver Connection Tests', () {
    test('1. Sender discovery listener starts successfully and binds UDP port', () async {
      final discovery = DiscoveryService();
      // Use an ephemeral port or standard 8889 for test isolation
      final result = await discovery.startRoomHost(
        pin: '1234',
        roomId: 'room_test_1',
        serverPort: serverPort,
        deviceName: 'Sender Device',
        discoveryPort: 8889,
      );

      expect(result, isA<RoomHostStartSuccess>());
      final success = result as RoomHostStartSuccess;
      expect(success.discoveryPort, equals(8889));
      expect(success.serverPort, equals(serverPort));

      discovery.stopRoomHost();
    });

    test('2. A UDP bind failure is surfaced explicitly instead of being silently ignored', () async {
      final discovery = DiscoveryService();

      // Inject simulated bind failure
      DiscoveryService.customSocketBinder = (host, port, {bool reuseAddress = false, bool reusePort = false, int ttl = 1}) async {
        throw const SocketException('Address already in use (EADDRINUSE)');
      };

      final result = await discovery.startRoomHost(
        pin: '9999',
        roomId: 'room_fail',
        serverPort: 8080,
        deviceName: 'Fail Device',
      );

      expect(result, isA<RoomHostStartFailure>());
      final failure = result as RoomHostStartFailure;
      expect(failure.reason, contains('UDP_BIND_FAILED'));
      expect(failure.error, isNotNull);

      DiscoveryService.customSocketBinder = null;
    });

    test('3. A receiver finds a host with a valid PIN and receives correct host IP and port', () async {
      final senderDiscovery = DiscoveryService();
      final receiverDiscovery = DiscoveryService();

      // Start host on loopback discovery port 8890
      final hostResult = await senderDiscovery.startRoomHost(
        pin: '4321',
        roomId: 'room_hotspot_test',
        serverPort: serverPort,
        deviceName: 'Pixel Hotspot Host',
        discoveryPort: 8890,
      );
      expect(hostResult, isA<RoomHostStartSuccess>());

      // Override local IP for predictable loopback discovery test
      NetworkUtils.customLocalIp = '127.0.0.1';

      final roomResult = await receiverDiscovery.discoverRoomResult(
        pin: '4321',
        discoveryPort: 8890,
        timeout: const Duration(seconds: 2),
      );

      expect(roomResult, isA<DiscoverRoomSuccess>());
      final room = (roomResult as DiscoverRoomSuccess).room;
      expect(room.pin, equals('4321'));
      expect(room.port, equals(serverPort));
      expect(room.deviceName, equals('Pixel Hotspot Host'));

      senderDiscovery.stopRoomHost();
    });

    test('4. Wrong PIN produces timeout and does not connect to host', () async {
      final senderDiscovery = DiscoveryService();
      final receiverDiscovery = DiscoveryService();

      await senderDiscovery.startRoomHost(
        pin: '7777',
        roomId: 'room_pin_mismatch',
        serverPort: serverPort,
        deviceName: 'Sender Device',
        discoveryPort: 8891,
      );

      NetworkUtils.customLocalIp = '127.0.0.1';

      // Receiver searches for wrong PIN '8888'
      final roomResult = await receiverDiscovery.discoverRoomResult(
        pin: '8888',
        discoveryPort: 8891,
        timeout: const Duration(milliseconds: 900),
      );

      expect(roomResult, isA<DiscoverRoomTimeout>());
      final timeout = roomResult as DiscoverRoomTimeout;
      expect(timeout.pin, equals('8888'));
      expect(timeout.targetsAttempted.isNotEmpty, isTrue);

      senderDiscovery.stopRoomHost();
    });

    test('5. Host IP and port are used for HTTP health check and pass', () async {
      final client = P2PHttpClient();
      final health = await client.checkHealth('127.0.0.1', serverPort);

      expect(health, isA<HealthCheckSuccess>());
      final success = health as HealthCheckSuccess;
      expect(success.peerId.isNotEmpty, isTrue);
      expect(success.deviceName.isNotEmpty, isTrue);
      expect(success.version, equals('1.0.0'));

      client.close();
    });

    test('6. Unreachable host produces HealthCheckUnreachable with distinct error message', () async {
      final client = P2PHttpClient();
      // Unused port
      final health = await client.checkHealth(
        '127.0.0.1',
        59999,
        timeout: const Duration(milliseconds: 500),
      );

      expect(health, isA<HealthCheckUnreachable>());
      final unreachable = health as HealthCheckUnreachable;
      expect(unreachable.message, contains('59999'));
      expect(unreachable.url, equals('http://127.0.0.1:59999/health'));

      client.close();
    });

    test('7. A reachable host passes /health and returns a valid batch manifest', () async {
      // Create test source file and register manifest
      final file = File('${tempDir.path}/test_image.png');
      await file.writeAsBytes(List.generate(2048, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 1024);
      server.setBatchManifests([(manifest: manifest, file: file)]);

      final client = P2PHttpClient();

      // Step 1: Health check
      final health = await client.checkHealth('127.0.0.1', serverPort);
      expect(health, isA<HealthCheckSuccess>());

      // Step 2: Batch manifest download
      final result = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(result, isA<BatchManifestFetchSuccess>());
      final batch = (result as BatchManifestFetchSuccess).batchManifest;
      expect(batch.totalFiles, equals(1));
      expect(batch.totalBytes, equals(2048));
      expect(batch.manifests.first.fileName, equals('test_image.png'));

      client.close();
    });

    test('8. Manifest-fetch failure does not mark receiver connected', () async {
      // Do not register any manifests on server
      final client = P2PHttpClient();

      final result = await client.downloadBatchManifest('127.0.0.1', serverPort, maxRetries: 1);
      expect(result, isA<BatchManifestFetchError>());
      final error = result as BatchManifestFetchError;
      expect(error.statusCode, equals(HttpStatus.notFound));

      client.close();
    });

    test('9. Direct-IP connection works when UDP discovery is blocked but HTTP is available', () async {
      // Create source file and register
      final file = File('${tempDir.path}/direct_file.txt');
      await file.writeAsString('Direct connection payload content');
      final manifest = await ManifestService.createManifest(file, chunkSize: 512);
      server.setBatchManifests([(manifest: manifest, file: file)]);

      final client = P2PHttpClient();

      // Simulate UDP broadcast blocked (e.g. hotspot client isolation)
      // Directly connect using Host IP and server port
      const directIp = '127.0.0.1';
      final health = await client.checkHealth(directIp, serverPort);
      expect(health, isA<HealthCheckSuccess>());

      final manifestResult = await client.downloadBatchManifest(directIp, serverPort);
      expect(manifestResult, isA<BatchManifestFetchSuccess>());
      final batch = (manifestResult as BatchManifestFetchSuccess).batchManifest;
      expect(batch.totalBytes, equals(manifest.fileSize));

      client.close();
    });

    test('10. NetworkUtils prioritizes Android Hotspot interface & private IP over cellular WAN', () async {
      // Setup fake interfaces: cellular rmnet (score should be low), wlan (medium), ap0 (highest)
      NetworkUtils.customInterfaces = [
        _FakeNetworkInterface(
          name: 'rmnet_data0',
          index: 1,
          addresses: [
            InternetAddress('100.64.0.12'),
          ],
        ),
        _FakeNetworkInterface(
          name: 'ap0', // Android Hotspot / SoftAP interface
          index: 2,
          addresses: [
            InternetAddress('192.168.43.1'),
          ],
        ),
        _FakeNetworkInterface(
          name: 'wlan0',
          index: 3,
          addresses: [
            InternetAddress('192.168.1.100'),
          ],
        ),
      ];

      final selectedIp = await NetworkUtils.getLocalIpAddress();
      // Should pick ap0's 192.168.43.1 because it is hotspot interface + standard hotspot subnet
      expect(selectedIp, equals('192.168.43.1'));

      final allIps = await NetworkUtils.getAllLocalIpAddresses();
      expect(allIps.first, equals('192.168.43.1'));
      expect(allIps.contains('192.168.1.100'), isTrue);
      // Cellular rmnet is completely excluded from candidates
      expect(allIps.contains('100.64.0.12'), isFalse);
    });

    test('11. MulticastLockService maintains balanced reference counting and releases cleanly', () async {
      expect(MulticastLockService.refCount, equals(0));

      await MulticastLockService.acquire();
      expect(MulticastLockService.refCount, equals(1));
      expect(MulticastLockService.isHeld, isTrue);

      await MulticastLockService.acquire();
      expect(MulticastLockService.refCount, equals(2));
      expect(MulticastLockService.isHeld, isTrue);

      await MulticastLockService.release();
      expect(MulticastLockService.refCount, equals(1));
      expect(MulticastLockService.isHeld, isTrue);

      await MulticastLockService.release();
      expect(MulticastLockService.refCount, equals(0));
      expect(MulticastLockService.isHeld, isFalse);

      await MulticastLockService.acquire();
      expect(MulticastLockService.refCount, equals(1));
      await MulticastLockService.forceReleaseAll();
      expect(MulticastLockService.refCount, equals(0));
      expect(MulticastLockService.isHeld, isFalse);
    });

    test('12. NetworkUtils.getDiscoveryTargets includes gateway .1 and standard hotspot subnets', () async {
      final targets = await NetworkUtils.getDiscoveryTargets(localIpOverride: '192.168.43.15');
      final targetIps = targets.map((t) => t.address).toSet();

      // Subnet broadcast
      expect(targetIps.contains('192.168.43.255'), isTrue);
      // Hotspot host unicast (.1)
      expect(targetIps.contains('192.168.43.1'), isTrue);
      // Global broadcast
      expect(targetIps.contains('255.255.255.255'), isTrue);
    });
  });
}
