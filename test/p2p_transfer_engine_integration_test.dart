import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/models/transfer.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/scheduler/sequential_priority_scheduler.dart';
import 'package:fluxshare/scheduler/ucb1_adaptive_scheduler.dart';
import 'package:fluxshare/transfer/transfer_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P2P TransferEngine Integration Tests', () {
    late Directory tempDir;
    late File sourceFile;
    late File destinationFile;
    late LocalServer server;

    setUp(() async {
      HttpOverrides.global = null;
      tempDir = await Directory.systemTemp.createTemp('fluxshare_engine_test_');
      sourceFile = File('${tempDir.path}/source_sample.bin');
      destinationFile = File('${tempDir.path}/received_sample.bin');

      // Create a 64 KB random binary payload
      final randomBytes = Uint8List(64 * 1024);
      for (int i = 0; i < randomBytes.length; i++) {
        randomBytes[i] = (i * 31) % 256;
      }
      await sourceFile.writeAsBytes(randomBytes, flush: true);

      server = LocalServer();
    });

    tearDown(() async {
      await server.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Transfers, writes offset chunks to disk, and passes 3-tier integrity verification', () async {
      // 1. Create real manifest with 16 KB chunk size (4 chunks total)
      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 16 * 1024);
      expect(manifest.chunkCount, equals(4));

      // 2. Start LocalServer hosting the file
      final port = await server.start(preferredPort: 0);
      expect(port, greaterThan(0));
      server.setManifest(manifest, sourceFile);

      // 3. Define peer info for the host server
      final hostPeer = PeerInfo(
        peerId: 'host-coordinator',
        deviceName: 'Host Device',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: port,
        webSocketPort: port,
        availableChunks: {0, 1, 2, 3},
        connectionStatus: 'available',
      );

      // 4. Configure TransferEngine with SequentialPriorityScheduler
      final scheduler = SequentialPriorityScheduler(priorityWindowSize: 2);
      final engine = TransferEngine(
        manifest: manifest,
        destinationFile: destinationFile,
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'rx-client-01',
        coordinatorPeerId: 'host-coordinator',
        concurrentWorkers: 2,
        scheduler: scheduler,
      );

      TransferProgressEvent? lastProgress;
      final progressSub = engine.progressStream.listen((event) {
        lastProgress = event;
      });

      // 5. Execute transfer to completion
      final success = await engine.start();
      await progressSub.cancel();

      expect(success, isTrue);
      expect(lastProgress?.status, equals(TransferStatus.completed));

      // 6. TIER 1: Destination file exists
      expect(await destinationFile.exists(), isTrue);

      // 7. TIER 2: Destination file size exactly matches source file
      final destLength = await destinationFile.length();
      expect(destLength, equals(manifest.fileSize));

      // 8. TIER 3: Whole-file SHA-256 matches manifest hash
      final destSha = await FileHasher.computeFileSha256(destinationFile);
      expect(destSha.toLowerCase(), equals(manifest.fileSha256.toLowerCase()));

      // 9. Clean up engine resources
      await engine.dispose();
    });

    test('Transfers cooperatively using UCB1 scheduler across multiple peers', () async {
      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 16 * 1024);
      final port = await server.start(preferredPort: 0);
      server.setManifest(manifest, sourceFile);

      // Coordinator holds all chunks
      final coordinator = PeerInfo(
        peerId: 'coord-01',
        deviceName: 'Coordinator Host',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: port,
        webSocketPort: port,
        availableChunks: {0, 1, 2, 3},
        connectionStatus: 'available',
      );

      final scheduler = UCB1AdaptiveScheduler(explorationConstant: 1.0);
      final engine = TransferEngine(
        manifest: manifest,
        destinationFile: destinationFile,
        swarmPeers: [coordinator],
        localServer: server,
        localPeerId: 'rx-client-02',
        coordinatorPeerId: 'coord-01',
        concurrentWorkers: 2,
        scheduler: scheduler,
      );

      final success = await engine.start();
      expect(success, isTrue);

      final destSha = await FileHasher.computeFileSha256(destinationFile);
      expect(destSha.toLowerCase(), equals(manifest.fileSha256.toLowerCase()));

      await engine.dispose();
    });
  });
}
