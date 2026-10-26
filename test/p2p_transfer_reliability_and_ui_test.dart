import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/chunk_manager.dart';
import 'package:fluxshare/models/chunk.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/models/transfer_failure_reason.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/websocket_service.dart';
import 'package:fluxshare/services/storage_diagnostics_service.dart';
import 'package:fluxshare/transfer/chunk_downloader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Part A: Transfer Failure Classification Tests', () {
    test('TransferFailureReason maps each failure class to distinct user-facing guidance', () {
      expect(
        TransferFailureReason.timeoutConnection.toUserMessage(),
        contains('Reconnecting to sender'),
      );
      expect(
        TransferFailureReason.timeoutBody.toUserMessage(),
        contains('Download stream stalled'),
      );
      expect(
        TransferFailureReason.diskSpaceInsufficient.toUserMessage(),
        contains('Not enough storage space'),
      );
      expect(
        TransferFailureReason.sha256Mismatch.toUserMessage(),
        contains('Chunk verification failed'),
      );
      expect(
        TransferFailureReason.notFound.toUserMessage(),
        contains('File or chunk not found on sender'),
      );
    });
  });

  group('Part B: Storage Diagnostics & Managed Temp File Tests', () {
    late Directory testTempDir;

    setUp(() async {
      testTempDir = await Directory.systemTemp.createTemp('fluxshare_storage_test_');
    });

    tearDown(() async {
      try {
        if (await testTempDir.exists()) {
          await testTempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Managed temp file registration and safe stale file cleanup', () async {
      final storageService = StorageDiagnosticsService();

      final activeTmp = File('${testTempDir.path}/fluxshare_tmp_active.tmp');
      await activeTmp.writeAsString('active content');
      storageService.registerManagedTempFile(activeTmp.path, 14);

      expect(storageService.isManagedTempFile(activeTmp.path), isTrue);

      final externalFile = File('${testTempDir.path}/user_photo.jpg');
      await externalFile.writeAsString('important user data');

      final cleanedCount = await storageService.cleanupManagedTempFiles(
        customTempDir: testTempDir,
        olderThan: const Duration(seconds: 0),
      );

      expect(cleanedCount, greaterThanOrEqualTo(1));
      expect(await activeTmp.exists(), isFalse);
      // External user file must NEVER be deleted
      expect(await externalFile.exists(), isTrue);
    });

    test('Storage check succeeds when space is sufficient', () async {
      final storageService = StorageDiagnosticsService();
      final hasSpace = await storageService.checkSufficientStorage(
        totalBytes: 1024,
        targetDirectoryPath: testTempDir.path,
      );
      expect(hasSpace, isTrue);
    });
  });

  group('Part C: Room Lifecycle & Handshake Synchronization Tests', () {
    late LocalServer hostServer;
    late int hostPort;
    late Directory hostTempDir;

    setUp(() async {
      HttpOverrides.global = null;
      hostTempDir = await Directory.systemTemp.createTemp('fluxshare_host_test_');
      hostServer = LocalServer();
      hostPort = await hostServer.start(preferredPort: 0);
    });

    tearDown(() async {
      await hostServer.stop();
      try {
        if (await hostTempDir.exists()) {
          await hostTempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Receiver connects, announces RECEIVER_JOINED and RECEIVER_READY, waits for TRANSFER_START', () async {
      final receiverWs = WebSocketService();
      final localReceiverId = 'receiver_peer_123';

      await receiverWs.connect(
        hostIp: '127.0.0.1',
        port: hostPort,
        localPeerId: localReceiverId,
      );

      // 1. Receiver sends RECEIVER_JOINED
      receiverWs.sendReceiverJoined(
        peerId: localReceiverId,
        deviceName: 'Pixel 8 Test Device',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      // Allow server to process WebSocket event
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(hostServer.connectedReceivers.length, equals(1));
      final connected = hostServer.connectedReceivers.first;
      expect(connected.peerId, equals(localReceiverId));
      expect(connected.deviceName, equals('Pixel 8 Test Device'));
      expect(connected.status, equals(ReceiverStatus.connected));

      // 2. Receiver performs storage check and sends RECEIVER_READY
      receiverWs.sendReceiverReady(
        peerId: localReceiverId,
        availableStorageBytes: 50 * 1024 * 1024 * 1024,
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));

      final ready = hostServer.connectedReceivers.first;
      expect(ready.status, equals(ReceiverStatus.ready));

      // 3. Receiver listens for TRANSFER_START
      bool receivedTransferStart = false;
      final sub = receiverWs.messageStream.listen((msg) {
        if (msg['type'] == 'TRANSFER_START') {
          receivedTransferStart = true;
        }
      });

      // Receiver must NOT receive TRANSFER_START before host broadcasts it
      expect(receivedTransferStart, isFalse);

      // 4. Host starts transfer
      hostServer.broadcastTransferStart(sessionId: 'test_session_1');

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(receivedTransferStart, isTrue);

      await sub.cancel();
      receiverWs.disconnect();
    });

    test('Late-joining receiver immediately receives TRANSFER_START if transfer has already started', () async {
      hostServer.broadcastTransferStart(sessionId: 'session_active');
      expect(hostServer.isTransferStarted, isTrue);

      final lateReceiverWs = WebSocketService();
      final latePeerId = 'late_joiner_999';

      bool receivedStartImmediate = false;
      final sub = lateReceiverWs.messageStream.listen((msg) {
        if (msg['type'] == 'TRANSFER_START') {
          receivedStartImmediate = true;
        }
      });

      await lateReceiverWs.connect(
        hostIp: '127.0.0.1',
        port: hostPort,
        localPeerId: latePeerId,
      );

      lateReceiverWs.sendReceiverJoined(
        peerId: latePeerId,
        deviceName: 'Late Device',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(receivedStartImmediate, isTrue);

      await sub.cancel();
      lateReceiverWs.disconnect();
    });
  });

  group('Part D & E: Multi-Receiver Concurrent Download & Isolation Tests', () {
    late LocalServer hostServer;
    late int hostPort;
    late Directory hostTempDir;
    late File sourceFile;
    late Manifest manifest;

    setUp(() async {
      HttpOverrides.global = null;
      hostTempDir = await Directory.systemTemp.createTemp('fluxshare_multi_rcv_test_');

      sourceFile = File('${hostTempDir.path}/test_video.mp4');
      final testData = List.generate(8192, (i) => (i * 17) % 256);
      await sourceFile.writeAsBytes(testData);

      final chunk0Bytes = testData.sublist(0, 2048);
      final chunk1Bytes = testData.sublist(2048, 4096);
      final chunk2Bytes = testData.sublist(4096, 6144);
      final chunk3Bytes = testData.sublist(6144, 8192);

      final sha0 = sha256.convert(chunk0Bytes).toString();
      final sha1 = sha256.convert(chunk1Bytes).toString();
      final sha2 = sha256.convert(chunk2Bytes).toString();
      final sha3 = sha256.convert(chunk3Bytes).toString();

      // Create manifest with 2048-byte chunks (4 chunks total)
      manifest = Manifest(
        fileId: 'file_multi_test_1',
        fileName: 'test_video.mp4',
        fileSize: testData.length,
        mimeType: 'video/mp4',
        chunkSize: 2048,
        chunkCount: 4,
        fileSha256: sha256.convert(testData).toString(),
        chunks: [
          ChunkMeta(chunkId: 0, offset: 0, length: 2048, sha256: sha0),
          ChunkMeta(chunkId: 1, offset: 2048, length: 2048, sha256: sha1),
          ChunkMeta(chunkId: 2, offset: 4096, length: 2048, sha256: sha2),
          ChunkMeta(chunkId: 3, offset: 6144, length: 2048, sha256: sha3),
        ],
      );

      hostServer = LocalServer();
      hostPort = await hostServer.start(preferredPort: 0);
      hostServer.replaceBatchManifests('batch_multi_1', [
        (manifest: manifest, file: sourceFile),
      ]);
    });

    tearDown(() async {
      await hostServer.stop();
      try {
        if (await hostTempDir.exists()) {
          await hostTempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Two independent receivers download chunks simultaneously from same host without contention', () async {
      final hostPeer = PeerInfo(
        peerId: hostServer.localPeerId,
        deviceName: hostServer.localDeviceName,
        platform: 'Android',
        ip: '127.0.0.1',
        httpPort: hostPort,
        webSocketPort: hostPort,
        availableChunks: {0, 1, 2, 3},
      );

      final destFile1 = File('${hostTempDir.path}/dest1.mp4');
      final destFile2 = File('${hostTempDir.path}/dest2.mp4');

      final writer1 = ChunkWriterSession(file: destFile1, totalSize: manifest.fileSize);
      final writer2 = ChunkWriterSession(file: destFile2, totalSize: manifest.fileSize);
      await writer1.open();
      await writer2.open();

      final downloader1 = ChunkDownloader();
      final downloader2 = ChunkDownloader();

      final future1 = downloader1.downloadChunk(
        peer: hostPeer,
        chunkMeta: manifest.chunks[0],
        writerSession: writer1,
        fileId: manifest.fileId,
      );

      final future2 = downloader2.downloadChunk(
        peer: hostPeer,
        chunkMeta: manifest.chunks[1],
        writerSession: writer2,
        fileId: manifest.fileId,
      );

      final results = await Future.wait<ChunkDownloadResult>([future1, future2]);

      expect(results[0].success, isTrue);
      expect(results[1].success, isTrue);
      expect(results[0].bytes, equals(2048));
      expect(results[1].bytes, equals(2048));

      await writer1.close();
      await writer2.close();

      // Verify that downloaded chunks match exact source file offsets
      final sourceBytes = await sourceFile.readAsBytes();
      final dest1Bytes = await destFile1.readAsBytes();
      final dest2Bytes = await destFile2.readAsBytes();

      expect(dest1Bytes.sublist(0, 2048), equals(sourceBytes.sublist(0, 2048)));
      expect(dest2Bytes.sublist(2048, 4096), equals(sourceBytes.sublist(2048, 4096)));
    });
  });
}
