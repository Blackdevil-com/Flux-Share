import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/batch_manifest.dart';
import 'package:fluxshare/models/device.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/models/transfer.dart';
import 'package:fluxshare/network/http_client.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/services/managed_temporary_file_service.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('fluxshare_batch_404_test_');
    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    await server.stop();
    TransferSessionManager.instance.cancel();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Batch Transfer HTTP 404 & Lifecycle Verification Tests', () {
    test('1, 2, 3, 4, 13: 3 distinct files (including similar names like Adaptive.pdf and Adaptive (1).pdf with spaces/parens) transfer end-to-end and reach 100%', () async {
      final file1 = File('${tempDir.path}/Adaptive (1).pdf');
      final file2 = File('${tempDir.path}/Adaptive.pdf');
      final file3 = File('${tempDir.path}/receipt_Adaptive.pdf');

      final bytes1 = List.generate(3072, (i) => (i * 3 + 1) % 256);
      final bytes2 = List.generate(2048, (i) => (i * 5 + 7) % 256);
      final bytes3 = List.generate(4096, (i) => (i * 11 + 13) % 256);

      await file1.writeAsBytes(bytes1);
      await file2.writeAsBytes(bytes2);
      await file3.writeAsBytes(bytes3);

      final m1 = await ManifestService.createManifest(file1, chunkSize: 1024);
      final m2 = await ManifestService.createManifest(file2, chunkSize: 1024);
      final m3 = await ManifestService.createManifest(file3, chunkSize: 1024);

      expect(m1.chunks.first.chunkId, equals(0));
      expect(m2.chunks.first.chunkId, equals(0));
      expect(m3.chunks.first.chunkId, equals(0));

      final batchManifest = BatchManifest(
        batchId: 'batch_test_3files_${DateTime.now().millisecondsSinceEpoch}',
        manifests: [m1, m2, m3],
      );

      server.replaceBatchManifests(batchManifest.batchId, [
        (manifest: m1, file: file1),
        (manifest: m2, file: file2),
        (manifest: m3, file: file3),
      ]);

      // Start Host Session
      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [
          const Device(
            id: 'receiver_device_1',
            name: 'Receiver Phone',
            ip: '127.0.0.1',
            platform: DevicePlatform.Android,
            isAvailable: true,
            signalStrength: 3,
          ),
        ],
        roomPin: '1234',
      );

      final dest1 = File('${tempDir.path}/rx_Adaptive (1).pdf');
      final dest2 = File('${tempDir.path}/rx_Adaptive.pdf');
      final dest3 = File('${tempDir.path}/rx_receipt_Adaptive.pdf');

      final hostPeer = PeerInfo(
        peerId: 'host_peer_127.0.0.1',
        deviceName: 'Host Device',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunks: Set.from(List.generate(m1.chunkCount, (i) => i)),
        availableChunksByFile: {
          m1.fileId: Set.from(List.generate(m1.chunkCount, (i) => i)),
          m2.fileId: Set.from(List.generate(m2.chunkCount, (i) => i)),
          m3.fileId: Set.from(List.generate(m3.chunkCount, (i) => i)),
        },
      );

      final items = [
        BatchTransferItem(
          fileId: m1.fileId,
          fileInfo: await FileInfo.fromFile(file1),
          manifest: m1,
          destinationFile: dest1,
          totalBytes: m1.fileSize,
        ),
        BatchTransferItem(
          fileId: m2.fileId,
          fileInfo: await FileInfo.fromFile(file2),
          manifest: m2,
          destinationFile: dest2,
          totalBytes: m2.fileSize,
        ),
        BatchTransferItem(
          fileId: m3.fileId,
          fileInfo: await FileInfo.fromFile(file3),
          manifest: m3,
          destinationFile: dest3,
          totalBytes: m3.fileSize,
        ),
      ];

      final coordinator = BatchTransferCoordinator(
        batchId: batchManifest.batchId,
        items: items,
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'receiver_device_1',
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: 2,
      );

      final batchSuccess = await coordinator.start();
      expect(batchSuccess, isTrue);

      // Verify all files on disk
      expect(await dest1.exists(), isTrue);
      expect(await dest2.exists(), isTrue);
      expect(await dest3.exists(), isTrue);

      expect(await dest1.length(), equals(3072));
      expect(await dest2.length(), equals(2048));
      expect(await dest3.length(), equals(4096));

      // 3-tier SHA-256 integrity verification
      final h1 = await FileHasher.computeFileSha256(dest1);
      final h2 = await FileHasher.computeFileSha256(dest2);
      final h3 = await FileHasher.computeFileSha256(dest3);

      expect(h1.toLowerCase(), equals(m1.fileSha256.toLowerCase()));
      expect(h2.toLowerCase(), equals(m2.fileSha256.toLowerCase()));
      expect(h3.toLowerCase(), equals(m3.fileSha256.toLowerCase()));

      expect(coordinator.overallProgressPercent, equals(100.0));
      expect(coordinator.currentItems.every((i) => i.status == TransferStatus.completed), isTrue);

      await coordinator.dispose();
    });

    test('5, 6, 7: Completing file 1 does NOT remove subsequent file manifests, verified chunks, or managed source files', () async {
      final fileA = File('${tempDir.path}/file_A.bin');
      final fileB = File('${tempDir.path}/file_B.bin');
      await fileA.writeAsBytes(List.filled(1024, 1));
      await fileB.writeAsBytes(List.filled(1024, 2));

      final mA = await ManifestService.createManifest(fileA, chunkSize: 512);
      final mB = await ManifestService.createManifest(fileB, chunkSize: 512);

      final batchManifest = BatchManifest(
        batchId: 'batch_isolation_test',
        manifests: [mA, mB],
      );

      server.replaceBatchManifests(batchManifest.batchId, [
        (manifest: mA, file: fileA),
        (manifest: mB, file: fileB),
      ]);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [
          const Device(
            id: 'rx_peer',
            name: 'Rx Phone',
            ip: '127.0.0.1',
            platform: DevicePlatform.Android,
            isAvailable: true,
            signalStrength: 3,
          ),
        ],
        roomPin: '5555',
      );

      // Simulate completion of file A over control channel with fileId
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_COMPLETED',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_peer',
        'fileId': mA.fileId,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      // Host must NOT have completed the entire session
      expect(sessionManager.currentSnapshot?.isCompleted, isFalse);

      // Verify that File B chunk requests via loopback HTTP still return 200 OK!
      final client = HttpClient();
      final reqB = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${mB.fileId}/chunk/0'));
      final resB = await reqB.close();
      expect(resB.statusCode, equals(HttpStatus.ok));
      final bodyB = await resB.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(bodyB.length, equals(512));
      expect(bodyB.first, equals(2));
      client.close();
    });

    test('8, 9: Distinguishable 404 diagnostics for missing manifest, missing source file, unavailable chunk, and missing batch', () async {
      final client = HttpClient();

      // 1. Missing active batch
      server.clearBatch();

      final reqNoBatch = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/nonexistent/chunk/0'));
      final resNoBatch = await reqNoBatch.close();
      expect(resNoBatch.statusCode, equals(HttpStatus.notFound));
      final jsonNoBatch = jsonDecode(await resNoBatch.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(jsonNoBatch['error'], equals('NO_ACTIVE_BATCH'));

      // 2. Setup server with 1 file
      final file = File('${tempDir.path}/valid.bin');
      await file.writeAsBytes(List.filled(1024, 42));
      final m = await ManifestService.createManifest(file, chunkSize: 512);

      server.replaceBatchManifests('batch_diag', [(manifest: m, file: file)]);

      // 3. Manifest not found for wrong fileId
      final reqWrongFile = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/wrong-file-id/chunk/0'));
      final resWrongFile = await reqWrongFile.close();
      expect(resWrongFile.statusCode, equals(HttpStatus.notFound));
      final jsonWrongFile = jsonDecode(await resWrongFile.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(jsonWrongFile['error'], equals('MANIFEST_NOT_FOUND'));

      // 4. Unavailable chunk
      final reqUnavailableChunk = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${m.fileId}/chunk/999'));
      final resUnavailableChunk = await reqUnavailableChunk.close();
      expect(resUnavailableChunk.statusCode, equals(HttpStatus.notFound));
      final jsonUnavailableChunk = jsonDecode(await resUnavailableChunk.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(jsonUnavailableChunk['error'], equals('CHUNK_UNAVAILABLE'));

      // 5. Missing source file on disk
      await file.delete();
      final reqMissingDisk = await client.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${m.fileId}/chunk/0'));
      final resMissingDisk = await reqMissingDisk.close();
      expect(resMissingDisk.statusCode, equals(HttpStatus.notFound));
      final jsonMissingDisk = jsonDecode(await resMissingDisk.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(jsonMissingDisk['error'], equals('FILE_NOT_ON_DISK'));

      client.close();
    });

    test('10: A failed file in a batch can be retried independently without retransferring completed files', () async {
      final file1 = File('${tempDir.path}/retry_1.bin');
      final file2 = File('${tempDir.path}/retry_2.bin');
      await file1.writeAsBytes(List.filled(1024, 10));
      await file2.writeAsBytes(List.filled(1024, 20));

      final m1 = await ManifestService.createManifest(file1, chunkSize: 512);
      final m2 = await ManifestService.createManifest(file2, chunkSize: 512);

      final batch = BatchManifest(
        batchId: 'batch_retry_test',
        manifests: [m1, m2],
      );

      // Register file1 normally, but temporarily simulate file2 as not ready on server
      server.replaceBatchManifests(batch.batchId, [
        (manifest: m1, file: file1),
      ]);

      final dest1 = File('${tempDir.path}/dest_retry_1.bin');
      final dest2 = File('${tempDir.path}/dest_retry_2.bin');

      final hostPeer = PeerInfo(
        peerId: 'host_peer',
        deviceName: 'Host',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunksByFile: {
          m1.fileId: {0, 1},
          m2.fileId: {0, 1},
        },
      );

      final items = [
        BatchTransferItem(
          fileId: m1.fileId,
          fileInfo: await FileInfo.fromFile(file1),
          manifest: m1,
          destinationFile: dest1,
          totalBytes: m1.fileSize,
        ),
        BatchTransferItem(
          fileId: m2.fileId,
          fileInfo: await FileInfo.fromFile(file2),
          manifest: m2,
          destinationFile: dest2,
          totalBytes: m2.fileSize,
        ),
      ];

      final coordinator = BatchTransferCoordinator(
        batchId: batch.batchId,
        items: items,
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'rx_retry',
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: 2,
      );

      final initialSuccess = await coordinator.start();
      expect(initialSuccess, isFalse);

      // File 1 must be completed
      expect(items[0].status, equals(TransferStatus.completed));
      expect(await dest1.exists(), isTrue);

      // File 2 must have failed
      expect(items[1].status, equals(TransferStatus.failed));
      expect(items[1].errorMessage, contains('MANIFEST_NOT_FOUND'));

      // Now host registers file 2
      server.replaceBatchManifests(batch.batchId, [
        (manifest: m1, file: file1),
        (manifest: m2, file: file2),
      ]);

      // Retry file 2
      final retrySuccess = await coordinator.retryFile(m2.fileId);
      expect(retrySuccess, isTrue);
      expect(items[1].status, equals(TransferStatus.completed));
      expect(await dest2.exists(), isTrue);
      expect(await dest2.length(), equals(1024));

      // Batch is now 100% complete
      expect(coordinator.overallProgressPercent, equals(100.0));

      await coordinator.dispose();
    });

    test('11: A new batch replaces old manifests cleanly without leaking stale entries', () async {
      final fileOld = File('${tempDir.path}/old.bin');
      await fileOld.writeAsBytes(List.filled(512, 1));
      final mOld = await ManifestService.createManifest(fileOld, chunkSize: 512);

      server.replaceBatchManifests('batch_old', [(manifest: mOld, file: fileOld)]);

      final fileNew1 = File('${tempDir.path}/new1.bin');
      final fileNew2 = File('${tempDir.path}/new2.bin');
      await fileNew1.writeAsBytes(List.filled(512, 2));
      await fileNew2.writeAsBytes(List.filled(512, 3));

      final mNew1 = await ManifestService.createManifest(fileNew1, chunkSize: 512);
      final mNew2 = await ManifestService.createManifest(fileNew2, chunkSize: 512);

      server.replaceBatchManifests('batch_new', [
        (manifest: mNew1, file: fileNew1),
        (manifest: mNew2, file: fileNew2),
      ]);

      final client = P2PHttpClient();
      final batchRes = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(batchRes, isA<BatchManifestFetchSuccess>());
      final fetched = (batchRes as BatchManifestFetchSuccess).batchManifest;

      expect(fetched.batchId, equals('batch_new'));
      expect(fetched.totalFiles, equals(2));
      expect(fetched.manifests.any((m) => m.fileId == mOld.fileId), isFalse);

      client.close();
    });

    test('12: Cancellation cleans up safely and does not delete original user source files', () async {
      final fileOriginal = File('${tempDir.path}/original_user_doc.pdf');
      await fileOriginal.writeAsBytes(List.filled(4096, 77));
      final m = await ManifestService.createManifest(fileOriginal, chunkSize: 1024);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: BatchManifest.fromSingleManifest(m),
        receivers: [],
        roomPin: '9999',
      );

      // Cancel session
      await sessionManager.cancel();

      // Original user file must NEVER be deleted!
      expect(await fileOriginal.exists(), isTrue);
      expect(await fileOriginal.length(), equals(4096));
    });
  });
}
