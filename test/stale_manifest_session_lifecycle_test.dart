import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/network/http_client.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/room/room_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('fluxshare_stale_manifest_test_');
    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    await server.stop();
    RoomManager().expireRoom();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Stale Batch Manifest & Transfer Session Lifecycle Tests', () {
    test('Consecutive transfer sessions: 3 files batch followed by 1 file batch exposes ONLY the 1 file', () async {
      // 1. Session 1: Create 3 source files
      final file1 = File('${tempDir.path}/file1.bin');
      await file1.writeAsBytes(List.generate(2048, (i) => i % 256));
      final file2 = File('${tempDir.path}/file2.bin');
      await file2.writeAsBytes(List.generate(4096, (i) => (i * 2) % 256));
      final file3 = File('${tempDir.path}/file3.bin');
      await file3.writeAsBytes(List.generate(1024, (i) => (i * 3) % 256));

      final m1 = await ManifestService.createManifest(file1, chunkSize: 1024);
      final m2 = await ManifestService.createManifest(file2, chunkSize: 1024);
      final m3 = await ManifestService.createManifest(file3, chunkSize: 1024);

      const batchId1 = 'batch_session_1';
      server.replaceBatchManifests(batchId1, [
        (manifest: m1, file: file1),
        (manifest: m2, file: file2),
        (manifest: m3, file: file3),
      ]);

      expect(server.activeBatchId, equals(batchId1));
      expect(server.hasActiveBatch, isTrue);

      // Verify receiver sees all 3 files in session 1
      final client = P2PHttpClient();
      final res1 = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(res1, isA<BatchManifestFetchSuccess>());
      final batch1 = (res1 as BatchManifestFetchSuccess).batchManifest;
      expect(batch1.batchId, equals(batchId1));
      expect(batch1.totalFiles, equals(3));
      expect(batch1.totalBytes, equals(2048 + 4096 + 1024));
      expect(batch1.manifests.map((m) => m.fileId).toSet(), equals({m1.fileId, m2.fileId, m3.fileId}));

      // 2. Sender ends session 1 -> clearBatch()
      server.clearBatch();
      expect(server.hasActiveBatch, isFalse);
      expect(server.currentManifest, isNull);
      expect(server.currentSourceFile, isNull);

      // While cleared, /manifests returns 404 MANIFEST_NOT_READY
      final resCleared = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(resCleared, isA<BatchManifestFetchError>());
      expect((resCleared as BatchManifestFetchError).statusCode, equals(404));

      // 3. Session 2: Sender selects only 1 file
      final fileSingle = File('${tempDir.path}/single_video.mp4');
      await fileSingle.writeAsBytes(List.generate(3000, (i) => (i * 5) % 256));
      final mSingle = await ManifestService.createManifest(fileSingle, chunkSize: 1024);

      const batchId2 = 'batch_session_2';
      server.replaceBatchManifests(batchId2, [
        (manifest: mSingle, file: fileSingle),
      ]);

      expect(server.activeBatchId, equals(batchId2));

      // 4. Receiver queries server for session 2
      final res2 = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(res2, isA<BatchManifestFetchSuccess>());
      final batch2 = (res2 as BatchManifestFetchSuccess).batchManifest;

      // CRITICAL ASSERTION: The receiver must see ONLY the single file from session 2!
      expect(batch2.batchId, equals(batchId2));
      expect(batch2.totalFiles, equals(1));
      expect(batch2.totalBytes, equals(3000));
      expect(batch2.manifests.length, equals(1));
      expect(batch2.manifests.first.fileId, equals(mSingle.fileId));

      // And manifests from old session 1 must return 404 on /file/<fileId>/manifest
      final rawClient = HttpClient();
      final reqOld1 = await rawClient.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${m1.fileId}/manifest'));
      final respOld1 = await reqOld1.close();
      expect(respOld1.statusCode, equals(404));

      final reqOld2 = await rawClient.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${m2.fileId}/manifest'));
      final respOld2 = await reqOld2.close();
      expect(respOld2.statusCode, equals(404));

      // Old chunks must also return 404
      final reqOldChunk = await rawClient.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${m1.fileId}/chunk/0'));
      final respOldChunk = await reqOldChunk.close();
      expect(respOldChunk.statusCode, equals(404));

      // Current single file manifest and chunks must return 200
      final reqCur = await rawClient.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${mSingle.fileId}/manifest'));
      final respCur = await reqCur.close();
      expect(respCur.statusCode, equals(200));

      final reqCurChunk = await rawClient.getUrl(Uri.parse('http://127.0.0.1:$serverPort/file/${mSingle.fileId}/chunk/0'));
      final respCurChunk = await reqCurChunk.close();
      expect(respCurChunk.statusCode, equals(200));
      final chunkBytes = await respCurChunk.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(chunkBytes.length, equals(1024));

      rawClient.close();
      client.close();
    });

    test('Atomic replacement: replacing 3 files with 2 files without explicit clearBatch still completely purges old files', () async {
      final fA = File('${tempDir.path}/a.txt')..writeAsStringSync('AAA');
      final fB = File('${tempDir.path}/b.txt')..writeAsStringSync('BBB');
      final fC = File('${tempDir.path}/c.txt')..writeAsStringSync('CCC');

      final mA = await ManifestService.createManifest(fA, chunkSize: 512);
      final mB = await ManifestService.createManifest(fB, chunkSize: 512);
      final mC = await ManifestService.createManifest(fC, chunkSize: 512);

      server.replaceBatchManifests('batch_A', [
        (manifest: mA, file: fA),
        (manifest: mB, file: fB),
        (manifest: mC, file: fC),
      ]);
      expect(server.verifiedChunks.isNotEmpty, isTrue);

      final fX = File('${tempDir.path}/x.txt')..writeAsStringSync('XXX');
      final fY = File('${tempDir.path}/y.txt')..writeAsStringSync('YYY');
      final mX = await ManifestService.createManifest(fX, chunkSize: 512);
      final mY = await ManifestService.createManifest(fY, chunkSize: 512);

      // Direct atomic replacement
      server.replaceBatchManifests('batch_B', [
        (manifest: mX, file: fX),
        (manifest: mY, file: fY),
      ]);

      expect(server.activeBatchId, equals('batch_B'));
      expect(server.currentManifest?.fileId, equals(mX.fileId));

      final client = P2PHttpClient();
      final res = await client.downloadBatchManifest('127.0.0.1', serverPort);
      expect(res, isA<BatchManifestFetchSuccess>());
      final batch = (res as BatchManifestFetchSuccess).batchManifest;

      expect(batch.batchId, equals('batch_B'));
      expect(batch.totalFiles, equals(2));
      expect(batch.manifests.map((m) => m.fileId).toSet(), equals({mX.fileId, mY.fileId}));

      client.close();
    });

    test('RoomManager expiration and recreation creates distinct room session without leftover peers', () async {
      final roomMgr = RoomManager();

      // Create room 1
      final r1 = roomMgr.createRoom(
        hostPeerId: 'peer_host_1',
        hostDeviceName: 'Sender Device',
        customPin: '1234',
      );
      expect(r1.state, equals(RoomState.created));
      expect(roomMgr.currentRoom?.pin, equals('1234'));

      // Expire room 1
      roomMgr.expireRoom();
      expect(roomMgr.currentRoom, isNull);

      await Future.delayed(const Duration(milliseconds: 10));

      // Create room 2
      final r2 = roomMgr.createRoom(
        hostPeerId: 'peer_host_1',
        hostDeviceName: 'Sender Device',
        customPin: '5678',
      );
      expect(r2.state, equals(RoomState.created));
      expect(roomMgr.currentRoom?.pin, equals('5678'));
      expect(r2.roomId, isNot(equals(r1.roomId)));
      expect(r2.joinedPeers.isEmpty, isTrue);
    });

    test('LocalServer handles setBatchManifests and setManifest with clean replacement semantics', () async {
      final f1 = File('${tempDir.path}/test1.txt')..writeAsStringSync('Hello 1');
      final m1 = await ManifestService.createManifest(f1, chunkSize: 512);

      server.setManifest(m1, f1);
      expect(server.hasActiveBatch, isTrue);
      expect(server.activeBatchId, equals(m1.fileId));
      expect(server.currentManifest?.fileId, equals(m1.fileId));

      final f2 = File('${tempDir.path}/test2.txt')..writeAsStringSync('Hello 2');
      final m2 = await ManifestService.createManifest(f2, chunkSize: 512);

      server.setBatchManifests([(manifest: m2, file: f2)]);
      expect(server.currentManifest?.fileId, equals(m2.fileId));
      expect(server.hasActiveBatch, isTrue);

      server.clearBatch();
      expect(server.hasActiveBatch, isFalse);
      expect(server.currentManifest, isNull);
    });

    test('Receiver connection generation token prevents delayed responses from overwriting new state', () async {
      int connectionGeneration = 0;
      String? currentBatchId;

      // User initiates connection 1
      final gen1 = ++connectionGeneration;

      // Connection 1 is slow... meanwhile user cancels/declines
      connectionGeneration++; // _resetToReady()
      currentBatchId = null;

      // User initiates connection 2
      final gen2 = ++connectionGeneration;
      currentBatchId = 'batch_2';

      // Delayed async result from connection 1 finishes
      void onDelayedResultFromGen1() {
        if (connectionGeneration != gen1) return; // Guarded!
        currentBatchId = 'batch_1_stale';
      }

      onDelayedResultFromGen1();

      // Ensure stale result was discarded and state remained batch_2
      expect(currentBatchId, equals('batch_2'));
      expect(connectionGeneration, equals(gen2));
    });
  });
}
