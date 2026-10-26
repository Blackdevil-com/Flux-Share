import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/models.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/network/websocket_service.dart';
import 'package:fluxshare/services/storage_path_service.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';
import 'package:fluxshare/transfer/transfer_engine.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer hostServer;
  late int hostPort;

  setUp(() async {
    HttpOverrides.global = null;
    NetworkUtils.customLocalIp = '127.0.0.1';

    tempDir = await Directory.systemTemp.createTemp('fluxshare_persist_sync_test_');
    StoragePathService.customSaveDirectory = Directory('${tempDir.path}/FluxShareDownloads');
    await StoragePathService.customSaveDirectory!.create(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => tempDir.path,
    );

    hostServer = LocalServer();
    hostPort = await hostServer.start(preferredPort: 19880);
    hostServer.clearReceivers();
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    StoragePathService.customSaveDirectory = null;
    StoragePathService.customScanFileHandler = null;
    hostServer.clearBatch();
    await hostServer.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Issue A — Receiver File Persistence and Confirm File on Disk', () {
    test('StoragePathService resolves destination folder and creates if absent', () async {
      final customDir = Directory('${tempDir.path}/CustomDownloads/FluxShare');
      StoragePathService.customSaveDirectory = customDir;

      final dir = await StoragePathService.getReceivedFilesDirectory();
      expect(dir.path, customDir.path);
      expect(await dir.exists(), isTrue);
    });

    test('StoragePathService.scanFile executes custom handler or platform channel safely', () async {
      String? scannedPath;
      StoragePathService.customScanFileHandler = (path) async {
        scannedPath = path;
      };

      await StoragePathService.scanFile('/storage/emulated/0/Download/FluxShare/sample.mp4');
      expect(scannedPath, '/storage/emulated/0/Download/FluxShare/sample.mp4');
    });

    test('TransferEngine saves file to configured destination and completes Tier 1-3 verification', () async {
      // 1. Create a dummy test file
      final sourceFile = File('${tempDir.path}/test_source.bin');
      final testData = List.generate(512 * 1024, (i) => i % 256); // 512 KB
      await sourceFile.writeAsBytes(testData);

      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 64 * 1024);
      hostServer.setManifest(manifest, sourceFile);

      // Destination in StoragePathService custom directory
      final saveDir = await StoragePathService.getReceivedFilesDirectory();
      final destFile = File('${saveDir.path}/received_${manifest.fileName}');

      String? mediaScannedFile;
      StoragePathService.customScanFileHandler = (path) async {
        mediaScannedFile = path;
      };

      final hostPeer = PeerInfo(
        peerId: hostServer.localPeerId,
        deviceName: 'HostDevice',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: hostPort,
        webSocketPort: hostPort,
        availableChunks: Set.from(List.generate(manifest.chunkCount, (i) => i)),
      );

      final engine = TransferEngine(
        destinationFile: destFile,
        manifest: manifest,
        swarmPeers: [hostPeer],
        localServer: hostServer,
        localPeerId: 'test_receiver_1',
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: 2,
      );

      final success = await engine.start();
      expect(success, isTrue);

      // Verify Tier 1: file exists on disk
      expect(await destFile.exists(), isTrue);
      // Verify Tier 2: size matches
      expect(await destFile.length(), manifest.fileSize);
      // Verify Tier 3: whole-file SHA-256 matches
      final destHash = await FileHasher.computeFileSha256(destFile);
      expect(destHash.toLowerCase(), manifest.fileSha256.toLowerCase());

      // Verify MediaScanner scan was invoked
      expect(mediaScannedFile, destFile.path);

      // Verify FileInfo created with destFile.path produces valid disk check
      final fileInfo = FileInfo.fromMetadata(
        path: destFile.path,
        name: manifest.fileName,
        sizeBytes: manifest.fileSize,
      );
      expect(fileInfo.id, destFile.path);
      final checkFile = File(fileInfo.id);
      expect(checkFile.existsSync(), isTrue);
      expect(checkFile.lengthSync(), manifest.fileSize);
    });
  });

  group('Issue B — Sender UI & Transfer State Synchronization', () {
    test('LocalServer chunk streaming tracks bytes and updates ConnectedReceiver automatically', () async {
      final sourceFile = File('${tempDir.path}/host_data.bin');
      final testData = List.generate(256 * 1024, (i) => i % 128); // 256 KB
      await sourceFile.writeAsBytes(testData);

      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 64 * 1024);
      hostServer.setManifest(manifest, sourceFile);

      // Register receiver in hostServer
      hostServer.updateReceiver(ConnectedReceiver(
        peerId: 'receiver_peer_abc',
        deviceName: 'Pixel 7',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      expect(hostServer.connectedReceivers.first.status, ReceiverStatus.connected);
      expect(hostServer.connectedReceivers.first.bytesReceived, 0);

      // Request chunk 0 with X-Peer-Id header
      final chunk0Url = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/0');
      final res0 = await http.get(chunk0Url, headers: {'X-Peer-Id': 'receiver_peer_abc'});
      expect(res0.statusCode, 200);

      // LocalServer should have recorded chunk 0 served
      var rx = hostServer.connectedReceivers.firstWhere((r) => r.peerId == 'receiver_peer_abc');
      expect(rx.status, ReceiverStatus.receiving);
      expect(rx.bytesReceived, 64 * 1024);
      expect(rx.progressPercent, closeTo(25.0, 0.5));

      // Request remaining chunks: 1, 2, 3
      for (int i = 1; i < manifest.chunkCount; i++) {
        final chunkUrl = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/$i');
        final res = await http.get(chunkUrl, headers: {'X-Peer-Id': 'receiver_peer_abc'});
        expect(res.statusCode, 200);
      }

      rx = hostServer.connectedReceivers.firstWhere((r) => r.peerId == 'receiver_peer_abc');
      expect(rx.status, ReceiverStatus.completed);
      expect(rx.bytesReceived, manifest.fileSize);
      expect(rx.progressPercent, 100.0);
    });

    test('LocalServer restores disconnected receiver to receiving when TRANSFER_PROGRESS is sent', () async {
      hostServer.updateReceiver(ConnectedReceiver(
        peerId: 'receiver_peer_xyz',
        deviceName: 'Galaxy S23',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.disconnected,
        progressPercent: 0.0,
        bytesReceived: 0,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 1)),
      ));

      expect(hostServer.connectedReceivers.first.status, ReceiverStatus.disconnected);

      // Connect WebSocket and send TRANSFER_PROGRESS
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: hostPort,
        localPeerId: 'receiver_peer_xyz',
      );

      wsService.send({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': 'session_1',
        'peerId': 'receiver_peer_xyz',
        'percent': 45.0,
        'bytesTransferred': 45000,
        'speedMbPerSec': 12.5,
      });

      // Wait briefly for WS dispatch
      await Future.delayed(const Duration(milliseconds: 100));

      final rx = hostServer.connectedReceivers.firstWhere((r) => r.peerId == 'receiver_peer_xyz');
      expect(rx.status, ReceiverStatus.receiving);
      expect(rx.progressPercent, 45.0);
      expect(rx.bytesReceived, 45000);

      wsService.disconnect();
    });

    test('TransferSessionManager startHostSession accurately tracks live receiver progress', () async {
      final sourceFile = File('${tempDir.path}/host_batch.bin');
      await sourceFile.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));

      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);
      hostServer.setBatchManifests([(manifest: manifest, file: sourceFile)]);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: hostServer,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '4980',
      );

      expect(sessionManager.hasActiveSession, isTrue);
      expect(sessionManager.currentSnapshot!.progressPercent, 0.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 0);

      // Receiver connects and sends progress
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: hostPort,
        localPeerId: 'peer_live_1',
      );

      wsService.sendReceiverJoined(
        peerId: 'peer_live_1',
        deviceName: 'Receiver Device',
        platform: 'android',
        ip: '127.0.0.1',
      );

      wsService.send({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'peer_live_1',
        'percent': 50.0,
        'bytesTransferred': 50 * 1024,
        'speedMbPerSec': 10.0,
      });

      await Future.delayed(const Duration(milliseconds: 150));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.progressPercent, 50.0);
      expect(snap.bytesTransferred, 50 * 1024);
      expect(snap.speedMbPerSec, 10.0);
      expect(snap.connectedReceivers.isNotEmpty, isTrue);

      // Send completion
      wsService.send({
        'type': 'TRANSFER_COMPLETED',
        'sessionId': batchManifest.batchId,
        'peerId': 'peer_live_1',
      });

      await Future.delayed(const Duration(milliseconds: 150));

      final completeSnap = sessionManager.currentSnapshot!;
      expect(completeSnap.progressPercent, 100.0);
      expect(completeSnap.isCompleted, isTrue);

      wsService.disconnect();
      sessionManager.dispose();
    });

    test('BatchTransferCoordinator communicates with host when WebSocket is preserved', () async {
      final sourceFile = File('${tempDir.path}/batch_coord.bin');
      await sourceFile.writeAsBytes(List.generate(128 * 1024, (i) => i % 256));

      final manifest = await ManifestService.createManifest(sourceFile, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);
      hostServer.setBatchManifests([(manifest: manifest, file: sourceFile)]);

      // Create connected WebSocket from receiver to host
      final wsService = WebSocketService();
      await wsService.connect(
        hostIp: '127.0.0.1',
        port: hostPort,
        localPeerId: 'coord_receiver_peer',
      );

      wsService.sendReceiverJoined(
        peerId: 'coord_receiver_peer',
        deviceName: 'Coord Receiver',
        platform: 'android',
        ip: '127.0.0.1',
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // Setup coordinator destination
      final saveDir = await StoragePathService.getReceivedFilesDirectory();
      final destFile = File('${saveDir.path}/coord_${manifest.fileName}');
      final fileInfo = FileInfo.fromMetadata(
        path: destFile.path,
        name: manifest.fileName,
        sizeBytes: manifest.fileSize,
      );

      final hostPeer = PeerInfo(
        peerId: hostServer.localPeerId,
        deviceName: 'Host',
        platform: 'android',
        ip: '127.0.0.1',
        httpPort: hostPort,
        webSocketPort: hostPort,
        availableChunks: Set.from(List.generate(manifest.chunkCount, (i) => i)),
      );

      final coordinator = BatchTransferCoordinator(
        batchId: batchManifest.batchId,
        items: [
          BatchTransferItem(
            fileId: manifest.fileId,
            fileInfo: fileInfo,
            manifest: manifest,
            destinationFile: destFile,
            totalBytes: manifest.fileSize,
          ),
        ],
        swarmPeers: [hostPeer],
        localServer: hostServer,
        webSocketService: wsService,
        localPeerId: 'coord_receiver_peer',
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: 2,
      );

      final progressEvents = <BatchProgressEvent>[];
      final sub = coordinator.progressStream.listen(progressEvents.add);

      final success = await coordinator.start();
      expect(success, isTrue);

      expect(destFile.existsSync(), isTrue);
      expect(destFile.lengthSync(), manifest.fileSize);

      await Future.delayed(const Duration(milliseconds: 150));

      // Verify hostServer received progress and completion
      final rx = hostServer.connectedReceivers.firstWhere((r) => r.peerId == 'coord_receiver_peer');
      expect(rx.progressPercent, 100.0);
      expect(rx.status, ReceiverStatus.completed);

      await sub.cancel();
      wsService.disconnect();
    });
  });
}
