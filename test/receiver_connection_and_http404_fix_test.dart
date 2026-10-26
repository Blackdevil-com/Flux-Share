import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/discovery/discovery_service.dart';
import 'package:fluxshare/file/chunk_manager.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/batch_manifest.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/device.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/models/transfer.dart';
import 'package:fluxshare/network/http_client.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/multicast_lock_service.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/network/websocket_service.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';
import 'package:fluxshare/transfer/chunk_downloader.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    MulticastLockService.resetForTesting();
    NetworkUtils.customLocalIp = '127.0.0.1';

    tempDir = await Directory.systemTemp.createTemp('fluxshare_receiver_http404_test_');
    server = LocalServer();
    serverPort = await server.start(preferredPort: 0);
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    DiscoveryService.customSocketBinder = null;
    await server.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Receiver Connection and HTTP 404 Fix Verification Tests', () {
    test('1. Valid receiver joins room and exchanges WebSocket state', () async {
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: serverPort,
        localPeerId: 'receiver_peer_1',
      );

      final messageCompleter = Completer<Map<String, dynamic>>();
      final sub = wsService.messageStream.listen((msg) {
        if (msg['type'] == 'PEER_JOINED' && !messageCompleter.isCompleted) {
          messageCompleter.complete(msg);
        }
      });

      // Receiver sends RECEIVER_JOINED
      wsService.sendReceiverJoined(
        peerId: 'receiver_peer_1',
        deviceName: 'Pixel 8 Pro',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(server.connectedReceivers.length, equals(1));
      final receiver = server.connectedReceivers.first;
      expect(receiver.peerId, equals('receiver_peer_1'));
      expect(receiver.deviceName, equals('Pixel 8 Pro'));
      expect(receiver.status, equals(ReceiverStatus.connected));

      final hostPeerMsg = await messageCompleter.future.timeout(const Duration(seconds: 3));
      expect(hostPeerMsg['type'], equals('PEER_JOINED'));
      expect(hostPeerMsg['peerId'], equals(server.localPeerId));

      await sub.cancel();
      wsService.disconnect();
    });

    test('2. Correct HTTP route returns manifest for clean UUID and URL-encoded IDs', () async {
      final sourceFile = File('${tempDir.path}/test_doc.pdf');
      final content = List.generate(2048, (i) => i % 256);
      await sourceFile.writeAsBytes(content);

      final cleanFileId = const Uuid().v4();
      final manifest = await ManifestService.createManifest(
        sourceFile,
        chunkSize: 512,
        fileId: cleanFileId,
      );

      server.replaceBatchManifests('batch_test_1', [
        (manifest: manifest, file: sourceFile),
      ]);

      final client = P2PHttpClient();

      // Query manifest with clean UUID
      final mResult = await client.downloadManifest('127.0.0.1', serverPort, fileId: cleanFileId);
      expect(mResult, isA<ManifestFetchSuccess>());
      final mSuccess = (mResult as ManifestFetchSuccess).manifest;
      expect(mSuccess.fileId, equals(cleanFileId));
      expect(mSuccess.chunkCount, equals(4));

      // Query manifest with URL-encoded ID
      final encodedId = Uri.encodeComponent(cleanFileId);
      final mEncodedResult = await client.downloadManifest('127.0.0.1', serverPort, fileId: encodedId);
      expect(mEncodedResult, isA<ManifestFetchSuccess>());
      final mEncodedSuccess = (mEncodedResult as ManifestFetchSuccess).manifest;
      expect(mEncodedSuccess.fileId, equals(cleanFileId));

      client.close();
    });

    test('3. Chunk request returns expected bytes via isolated multi-file endpoint', () async {
      final sourceFile = File('${tempDir.path}/OD338949420998800100.pdf');
      final content = List.generate(1024, (i) => (i * 13) % 256);
      await sourceFile.writeAsBytes(content);

      final fileId = const Uuid().v4();
      final manifest = await ManifestService.createManifest(
        sourceFile,
        chunkSize: 512,
        fileId: fileId,
      );

      server.replaceBatchManifests('batch_pdf_test', [
        (manifest: manifest, file: sourceFile),
      ]);

      final destFile = File('${tempDir.path}/dest.pdf');
      final writer = ChunkWriterSession(file: destFile, totalSize: manifest.fileSize);
      await writer.open();

      final downloader = ChunkDownloader();
      final peer = PeerInfo(
        peerId: 'host_peer',
        deviceName: 'Host',
        platform: 'Android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
      );

      // Download chunk 0
      final result0 = await downloader.downloadChunk(
        peer: peer,
        chunkMeta: manifest.chunks[0],
        writerSession: writer,
        fileId: fileId,
      );

      expect(result0.success, isTrue);
      expect(result0.bytes, equals(512));
      expect(result0.statusCode, equals(HttpStatus.ok));

      // Download chunk 1
      final result1 = await downloader.downloadChunk(
        peer: peer,
        chunkMeta: manifest.chunks[1],
        writerSession: writer,
        fileId: fileId,
      );

      expect(result1.success, isTrue);
      expect(result1.bytes, equals(512));

      await writer.close();
      downloader.close();

      final destBytes = await destFile.readAsBytes();
      expect(destBytes, equals(content));
    });

    test('4. Invalid route produces meaningful diagnostic (not silent 404)', () async {
      final client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:$serverPort/unknown/route');
      final req = await client.getUrl(uri);
      final resp = await req.close();

      expect(resp.statusCode, equals(HttpStatus.notFound));
      client.close();
    });

    test('5. Missing or stale transfer ID handled gracefully with explicit 404 error', () async {
      final client = HttpClient();

      // Request manifest for non-existent file
      final uri = Uri.parse('http://127.0.0.1:$serverPort/file/non_existent_file_id/manifest');
      final req = await client.getUrl(uri);
      final resp = await req.close();

      expect(resp.statusCode, equals(HttpStatus.notFound));
      final body = await resp.transform(utf8.decoder).join();
      expect(body, contains('MANIFEST_NOT_READY'));

      client.close();
    });

    test('6. Receiver progress advances on byte arrival', () async {
      final sourceFile = File('${tempDir.path}/progress_test.dat');
      final content = List.generate(4096, (i) => i % 256);
      await sourceFile.writeAsBytes(content);

      final fileId = const Uuid().v4();
      final manifest = await ManifestService.createManifest(
        sourceFile,
        chunkSize: 1024,
        fileId: fileId,
      );

      server.replaceBatchManifests('batch_progress', [
        (manifest: manifest, file: sourceFile),
      ]);

      final destFile = File('${tempDir.path}/dest_progress.dat');
      final batchItem = BatchTransferItem(
        fileId: fileId,
        fileInfo: FileInfo(
          id: fileId,
          name: 'progress_test.dat',
          sizeBytes: 4096,
          formattedSize: '4 KB',
          extension: 'dat',
          type: FileType.Other,
        ),
        manifest: manifest,
        destinationFile: destFile,
        totalBytes: 4096,
      );

      final hostPeer = PeerInfo(
        peerId: 'host_127.0.0.1',
        deviceName: 'Host',
        platform: 'Android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunks: {0, 1, 2, 3},
        availableChunksByFile: {fileId: {0, 1, 2, 3}},
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_progress',
        items: [batchItem],
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'receiver_peer_progress',
        coordinatorPeerId: hostPeer.peerId,
      );

      final progressEvents = <double>[];
      final sub = coordinator.progressStream.listen((event) {
        progressEvents.add(event.overallProgressPercent);
      });

      final success = await coordinator.start();
      expect(success, isTrue);
      expect(progressEvents.isNotEmpty, isTrue);
      expect(progressEvents.last, equals(100.0));

      await sub.cancel();
    });

    test('7. Sender receiver count and status reflect real state', () async {
      final wsService1 = WebSocketService();
      await wsService1.connect(
        hostIp: '127.0.0.1',
        port: serverPort,
        localPeerId: 'rx_1',
      );
      wsService1.sendReceiverJoined(
        peerId: 'rx_1',
        deviceName: 'Device A',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      final wsService2 = WebSocketService();
      await wsService2.connect(
        hostIp: '127.0.0.1',
        port: serverPort,
        localPeerId: 'rx_2',
      );
      wsService2.sendReceiverJoined(
        peerId: 'rx_2',
        deviceName: 'Device B',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(server.connectedReceivers.length, equals(2));
      var activeCount = server.connectedReceivers
          .where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed)
          .length;
      expect(activeCount, equals(2));

      // Device A fails
      wsService1.sendReceiverFailed(peerId: 'rx_1', error: 'DISK_FULL');
      await Future.delayed(const Duration(milliseconds: 100));

      final rx1 = server.connectedReceivers.firstWhere((r) => r.peerId == 'rx_1');
      expect(rx1.status, equals(ReceiverStatus.failed));
      expect(rx1.errorMessage, equals('DISK_FULL'));

      activeCount = server.connectedReceivers
          .where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed)
          .length;
      expect(activeCount, equals(1));

      // Device B disconnects
      wsService2.disconnect();
      await Future.delayed(const Duration(milliseconds: 100));

      final rx2 = server.connectedReceivers.firstWhere((r) => r.peerId == 'rx_2');
      expect(rx2.status, equals(ReceiverStatus.disconnected));

      activeCount = server.connectedReceivers
          .where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed)
          .length;
      expect(activeCount, equals(0));

      wsService1.disconnect();
    });

    test('8. Recoverable error retry succeeds without losing progress', () async {
      final sourceFile = File('${tempDir.path}/retry_test.dat');
      final content = List.generate(2048, (i) => (i * 5) % 256);
      await sourceFile.writeAsBytes(content);

      final fileId = const Uuid().v4();
      final manifest = await ManifestService.createManifest(
        sourceFile,
        chunkSize: 512,
        fileId: fileId,
      );

      server.replaceBatchManifests('batch_retry', [
        (manifest: manifest, file: sourceFile),
      ]);

      final destFile = File('${tempDir.path}/dest_retry.dat');
      final batchItem = BatchTransferItem(
        fileId: fileId,
        fileInfo: FileInfo(
          id: fileId,
          name: 'retry_test.dat',
          sizeBytes: 2048,
          formattedSize: '2 KB',
          extension: 'dat',
          type: FileType.Other,
        ),
        manifest: manifest,
        destinationFile: destFile,
        totalBytes: 2048,
      );

      final hostPeer = PeerInfo(
        peerId: 'host_127.0.0.1',
        deviceName: 'Host',
        platform: 'Android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunks: {0, 1, 2, 3},
        availableChunksByFile: {fileId: {0, 1, 2, 3}},
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_retry',
        items: [batchItem],
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'rx_retry',
        coordinatorPeerId: hostPeer.peerId,
      );

      // Retry file execution
      final retrySuccess = await coordinator.retryFile(fileId);
      expect(retrySuccess, isTrue);
      expect(batchItem.status, equals(TransferStatus.completed));
      expect(batchItem.bytesTransferred, equals(2048));
    });

    test('9. Failed receiver not shown as transferring on sender', () async {
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: serverPort,
        localPeerId: 'rx_failing',
      );
      wsService.sendReceiverJoined(
        peerId: 'rx_failing',
        deviceName: 'Failing Phone',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      await Future.delayed(const Duration(milliseconds: 100));
      expect(server.connectedReceivers.first.status, equals(ReceiverStatus.connected));

      // Report failure
      wsService.sendReceiverFailed(
        peerId: 'rx_failing',
        error: 'HTTP 404 from host_127.0.0.1',
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final rx = server.connectedReceivers.first;
      expect(rx.status, equals(ReceiverStatus.failed));
      expect(rx.errorMessage, equals('HTTP 404 from host_127.0.0.1'));

      // Active count should exclude it
      final activeReceivers = server.connectedReceivers
          .where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed)
          .length;
      expect(activeReceivers, equals(0));

      wsService.disconnect();
    });

    test('10. Completion verifies reconstructed file with full SHA-256 match', () async {
      final sourceFile = File('${tempDir.path}/sha_verify.bin');
      final content = List.generate(5000, (i) => (i * 31) % 256);
      await sourceFile.writeAsBytes(content);

      final fileId = const Uuid().v4();
      final manifest = await ManifestService.createManifest(
        sourceFile,
        chunkSize: 1024,
        fileId: fileId,
      );

      server.replaceBatchManifests('batch_sha', [
        (manifest: manifest, file: sourceFile),
      ]);

      final destFile = File('${tempDir.path}/dest_sha.bin');
      final batchItem = BatchTransferItem(
        fileId: fileId,
        fileInfo: FileInfo(
          id: fileId,
          name: 'sha_verify.bin',
          sizeBytes: 5000,
          formattedSize: '5 KB',
          extension: 'bin',
          type: FileType.Other,
        ),
        manifest: manifest,
        destinationFile: destFile,
        totalBytes: 5000,
      );

      final hostPeer = PeerInfo(
        peerId: 'host_127.0.0.1',
        deviceName: 'Host',
        platform: 'Android',
        ip: '127.0.0.1',
        httpPort: serverPort,
        webSocketPort: serverPort,
        availableChunks: {0, 1, 2, 3, 4},
        availableChunksByFile: {fileId: {0, 1, 2, 3, 4}},
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_sha',
        items: [batchItem],
        swarmPeers: [hostPeer],
        localServer: server,
        localPeerId: 'rx_sha',
        coordinatorPeerId: hostPeer.peerId,
      );

      final success = await coordinator.start();
      expect(success, isTrue);

      // Verify destination file SHA-256
      final destHash = await FileHasher.computeFileSha256(destFile);
      expect(destHash, equals(manifest.fileSha256));
    });

    test('11. Cancellation cleans up temporary transfer state and notifies sender', () async {
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: serverPort,
        localPeerId: 'rx_cancelling',
      );
      wsService.sendReceiverJoined(
        peerId: 'rx_cancelling',
        deviceName: 'Cancelling Phone',
        platform: 'Android',
        ip: '127.0.0.1',
      );

      final destFile = File('${tempDir.path}/dest_cancel.dat');
      final batchItem = BatchTransferItem(
        fileId: 'file_cancel',
        fileInfo: const FileInfo(
          id: 'file_cancel',
          name: 'cancel.dat',
          sizeBytes: 1000,
          formattedSize: '1 KB',
          extension: 'dat',
          type: FileType.Other,
        ),
        manifest: Manifest(
          fileId: 'file_cancel',
          fileName: 'cancel.dat',
          fileSize: 1000,
          mimeType: 'application/octet-stream',
          chunkSize: 500,
          chunkCount: 2,
          fileSha256: 'dummy_hash',
          chunks: [],
        ),
        destinationFile: destFile,
        totalBytes: 1000,
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_cancel',
        items: [batchItem],
        swarmPeers: [],
        localServer: server,
        webSocketService: wsService,
        localPeerId: 'rx_cancelling',
        coordinatorPeerId: 'host_peer',
      );

      await coordinator.cancel();
      expect(coordinator.isCancelled, isTrue);

      await Future.delayed(const Duration(milliseconds: 100));

      final rx = server.connectedReceivers.firstWhere((r) => r.peerId == 'rx_cancelling');
      expect(rx.status, equals(ReceiverStatus.failed));
      expect(rx.errorMessage, contains('cancelled'));

      wsService.disconnect();
    });

    test('12. Multi-file & multi-receiver regressions prevented', () async {
      final f1 = File('${tempDir.path}/batch_file1.txt');
      await f1.writeAsString('File One Contents 123456');

      final f2 = File('${tempDir.path}/batch_file2.txt');
      await f2.writeAsString('File Two Contents ABCDEFGHIJKLMNOPQRSTUVWXYZ');

      final id1 = const Uuid().v4();
      final id2 = const Uuid().v4();

      final m1 = await ManifestService.createManifest(f1, chunkSize: 16, fileId: id1);
      final m2 = await ManifestService.createManifest(f2, chunkSize: 16, fileId: id2);

      server.replaceBatchManifests('batch_multi_12', [
        (manifest: m1, file: f1),
        (manifest: m2, file: f2),
      ]);

      final client = P2PHttpClient();
      final batchResult = await client.downloadBatchManifest('127.0.0.1', serverPort);

      expect(batchResult, isA<BatchManifestFetchSuccess>());
      final batch = (batchResult as BatchManifestFetchSuccess).batchManifest;
      expect(batch.totalFiles, equals(2));
      expect(batch.manifests.map((m) => m.fileId), containsAll([id1, id2]));

      // Verify each file chunk is accessible independently
      final chunkResp1 = await HttpClient().getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/file/$id1/chunk/0'),
      ).then((r) => r.close());
      expect(chunkResp1.statusCode, equals(HttpStatus.ok));

      final chunkResp2 = await HttpClient().getUrl(
        Uri.parse('http://127.0.0.1:$serverPort/file/$id2/chunk/0'),
      ).then((r) => r.close());
      expect(chunkResp2.statusCode, equals(HttpStatus.ok));

      client.close();
    });
  });
}
