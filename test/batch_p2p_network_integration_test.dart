import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/network/http_client.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    // Disable flutter_test's default HttpClient mocking for real loopback transfers
    HttpOverrides.global = null;

    tempDir = await Directory.systemTemp.createTemp('fluxshare_batch_network_test_');
    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    await server.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Batch P2P TransferEngine & Network Integration Tests', () {
    test('Transfers multiple files via BatchTransferCoordinator with distinct chunk endpoints and passes 3-tier SHA-256 verification', () async {
      // Create two distinct source files on disk
      final fileA = File('${tempDir.path}/source_video.mp4');
      final bytesA = List.generate(4096, (i) => (i * 3) % 256);
      await fileA.writeAsBytes(bytesA);

      final fileB = File('${tempDir.path}/source_notes.txt');
      final bytesB = List.generate(1500, (i) => (i * 7) % 256);
      await fileB.writeAsBytes(bytesB);

      // Generate manifests with small chunk size so each file has multiple chunks
      final manifestA = await ManifestService.createManifest(fileA, chunkSize: 1024);
      final manifestB = await ManifestService.createManifest(fileB, chunkSize: 512);

      expect(manifestA.chunkCount, equals(4)); // 4096 / 1024
      expect(manifestB.chunkCount, equals(3)); // 1500 / 512 = 3

      // Register both manifests on the server
      server.setBatchManifests([
        (manifest: manifestA, file: fileA),
        (manifest: manifestB, file: fileB),
      ]);

      // Verify that P2PHttpClient downloads the BatchManifest containing both files
      final client = P2PHttpClient();
      final batchResult = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(batchResult, isA<BatchManifestFetchSuccess>());
      final fetchedBatch = (batchResult as BatchManifestFetchSuccess).batchManifest;
      expect(fetchedBatch.totalFiles, equals(2));
      expect(fetchedBatch.totalBytes, equals(4096 + 1500));

      // Setup destination files for the receiver
      final destA = File('${tempDir.path}/dest_video.mp4');
      final destB = File('${tempDir.path}/dest_notes.txt');

      final hostPeer = PeerInfo(
        peerId: 'host_peer',
        deviceName: 'Host Device',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunks: Set.from(List.generate(4, (i) => i)),
        availableChunksByFile: {
          manifestA.fileId: Set.from(List.generate(4, (i) => i)),
          manifestB.fileId: Set.from(List.generate(3, (i) => i)),
        },
      );

      final itemA = BatchTransferItem(
        fileId: manifestA.fileId,
        fileInfo: await FileInfo.fromFile(fileA),
        manifest: manifestA,
        destinationFile: destA,
        totalBytes: manifestA.fileSize,
      );

      final itemB = BatchTransferItem(
        fileId: manifestB.fileId,
        fileInfo: await FileInfo.fromFile(fileB),
        manifest: manifestB,
        destinationFile: destB,
        totalBytes: manifestB.fileSize,
      );

      final coordinator = BatchTransferCoordinator(
        batchId: fetchedBatch.batchId,
        items: [itemA, itemB],
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'receiver_peer',
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: 3,
      );

      // Execute batch transfer
      final batchSuccess = await coordinator.start();
      expect(batchSuccess, isTrue);

      // TIER 1: Both destination files must exist on disk
      expect(await destA.exists(), isTrue);
      expect(await destB.exists(), isTrue);

      // TIER 2: Destination file sizes must match manifests exactly
      expect(await destA.length(), equals(manifestA.fileSize));
      expect(await destB.length(), equals(manifestB.fileSize));

      // TIER 3: Whole-file SHA-256 must match original files exactly (no chunk mixing!)
      final hashDestA = await FileHasher.computeFileSha256(destA);
      final hashDestB = await FileHasher.computeFileSha256(destB);

      expect(hashDestA.toLowerCase(), equals(manifestA.fileSha256.toLowerCase()));
      expect(hashDestB.toLowerCase(), equals(manifestB.fileSha256.toLowerCase()));

      await coordinator.dispose();
      client.close();
    });

    test('Single-file legacy /chunk/<chunkId> and /manifest endpoints continue to work seamlessly', () async {
      final fileSingle = File('${tempDir.path}/single.dat');
      await fileSingle.writeAsBytes(List.filled(2048, 99));

      final manifestSingle = await ManifestService.createManifest(fileSingle, chunkSize: 1024);
      server.setManifest(manifestSingle, fileSingle);

      final client = P2PHttpClient();
      final manifestResult = await client.downloadManifest('127.0.0.1', serverPort);

      expect(manifestResult, isA<ManifestFetchSuccess>());
      final fetched = (manifestResult as ManifestFetchSuccess).manifest;
      expect(fetched.fileName, equals('single.dat'));
      expect(fetched.fileSize, equals(2048));

      final destSingle = File('${tempDir.path}/dest_single.dat');
      final chunkSuccess = await client.downloadChunk('127.0.0.1', serverPort, fetched.chunks.first, destSingle);
      expect(chunkSuccess, isTrue);
      expect(await destSingle.exists(), isTrue);
      expect(await destSingle.length(), equals(1024));

      client.close();
    });
  });
}
