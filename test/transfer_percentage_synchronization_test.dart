import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/models.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/services/storage_path_service.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer server;
  late int serverPort;

  setUp(() async {
    HttpOverrides.global = null;
    NetworkUtils.customLocalIp = '127.0.0.1';

    tempDir = await Directory.systemTemp.createTemp('fluxshare_sync_test_');
    StoragePathService.customSaveDirectory = Directory('${tempDir.path}/Downloads');
    await StoragePathService.customSaveDirectory!.create(recursive: true);

    server = LocalServer();
    // Default server has enableServedBytesAsProgressFallback = false,
    // ensuring progress is strictly driven by authoritative receiver confirmations.
    serverPort = await server.start(preferredPort: 19892);
    server.clearReceivers();
    await TransferSessionManager.instance.cancel();
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    StoragePathService.customSaveDirectory = null;
    await TransferSessionManager.instance.cancel();
    server.clearBatch();
    await server.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Sender and Receiver Exact Percentage Synchronization Tests', () {
    test('1. Both sides display the same percentage for the same authoritative progress update', () async {
      // 100 KB test file
      final file = File('${tempDir.path}/sync_test_1.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 32 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1111',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_sync_1',
        deviceName: 'Receiver 1',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Receiver reports confirmed 20%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_sync_1',
        'percent': 20.0,
        'bytesTransferred': 20 * 1024,
        'totalBytes': 100 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      final hostSnap = sessionManager.currentSnapshot!;
      expect(hostSnap.progressPercent, 20.0);
      expect(hostSnap.bytesTransferred, 20 * 1024);
      expect(hostSnap.receiverProgressMap['rx_sync_1'], 20.0);
    });

    test('2. Sender and receiver remain synchronized at several intermediate percentages', () async {
      final file = File('${tempDir.path}/sync_test_2.bin');
      await file.writeAsBytes(List.generate(1000 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '2222',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_steps',
        deviceName: 'Receiver Steps',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Test critical checkpoints: 20%, 45%, 78%
      final checkpoints = [20.0, 45.0, 78.0];
      for (final targetPct in checkpoints) {
        final targetBytes = ((targetPct / 100.0) * (1000 * 1024)).round();
        server.notifyControlListenersForTesting({
          'type': 'TRANSFER_PROGRESS',
          'sessionId': batchManifest.batchId,
          'peerId': 'rx_steps',
          'percent': targetPct,
          'bytesTransferred': targetBytes,
          'totalBytes': 1000 * 1024,
        });

        await Future.delayed(const Duration(milliseconds: 50));

        final snap = sessionManager.currentSnapshot!;
        expect(snap.progressPercent, targetPct, reason: 'Sender must match receiver at $targetPct%');
        expect(snap.bytesTransferred, targetBytes);
      }
    });

    test('3. Served bytes do not cause sender progress to exceed receiver-confirmed progress', () async {
      final file = File('${tempDir.path}/sync_served_test.bin');
      await file.writeAsBytes(List.generate(256 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      server.setBatchManifests([(manifest: manifest, file: file)]);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '3333',
      );

      server.markReceiverAsWebSocketForTesting('rx_served');
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_served',
        deviceName: 'Receiver Served',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Client requests chunks 0 and 1 over HTTP (128 KB = 50% served)
      final url0 = Uri.parse('http://127.0.0.1:$serverPort/file/${manifest.fileId}/chunk/0');
      final url1 = Uri.parse('http://127.0.0.1:$serverPort/file/${manifest.fileId}/chunk/1');

      final res0 = await http.get(url0, headers: {'X-Peer-Id': 'rx_served'});
      final res1 = await http.get(url1, headers: {'X-Peer-Id': 'rx_served'});
      expect(res0.statusCode, 200);
      expect(res1.statusCode, 200);

      await Future.delayed(const Duration(milliseconds: 50));

      // CRITICAL GUARANTEE: Served HTTP chunks must NOT advance sender progress!
      // Progress remains at 0% until receiver confirms verified commit.
      expect(sessionManager.currentSnapshot!.progressPercent, 0.0,
          reason: 'Sender progress must NOT advance from served bytes alone without receiver confirmation');
      expect(sessionManager.currentSnapshot!.bytesTransferred, 0);

      // Now receiver confirms 25% (it has committed chunk 0 only)
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_served',
        'percent': 25.0,
        'bytesTransferred': 64 * 1024,
        'totalBytes': 256 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      // Now sender advances exactly to the receiver-confirmed 25%, not the 50% served!
      expect(sessionManager.currentSnapshot!.progressPercent, 25.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 64 * 1024);
    });

    test('4. Duplicate progress messages do not change the percentage incorrectly', () async {
      final file = File('${tempDir.path}/sync_dup_test.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '4444',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_dup',
        deviceName: 'Receiver Dup',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      for (int i = 0; i < 5; i++) {
        server.notifyControlListenersForTesting({
          'type': 'TRANSFER_PROGRESS',
          'sessionId': batchManifest.batchId,
          'peerId': 'rx_dup',
          'percent': 35.0,
          'bytesTransferred': 35 * 1024,
        });
      }

      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.progressPercent, 35.0);
      expect(snap.bytesTransferred, 35 * 1024);
    });

    test('5. Out-of-order messages cannot overwrite newer confirmed progress', () async {
      final file = File('${tempDir.path}/sync_order_test.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '5555',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_order',
        deviceName: 'Receiver Order',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Advance to 60%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_order',
        'percent': 60.0,
        'bytesTransferred': 60 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 60.0);

      // Stale out-of-order update arrives reporting 40%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_order',
        'percent': 40.0,
        'bytesTransferred': 40 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      // Progress must remain at 60%
      expect(sessionManager.currentSnapshot!.progressPercent, 60.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 60 * 1024);
    });

    test('6. Updates from an old session are ignored', () async {
      final file = File('${tempDir.path}/sync_sess_test.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '6666',
        sessionId: 'current_active_session',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_sess',
        deviceName: 'Receiver Sess',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Message arrives with obsolete sessionId
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': 'old_obsolete_session',
        'peerId': 'rx_sess',
        'percent': 80.0,
        'bytesTransferred': 80 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      // Progress must NOT be polluted by old session
      expect(sessionManager.currentSnapshot!.progressPercent, 0.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 0);

      // Valid message with current sessionId
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': 'current_active_session',
        'peerId': 'rx_sess',
        'percent': 40.0,
        'bytesTransferred': 40 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 40.0);
    });

    test('7. Multiple receivers are aggregated according to the documented definition', () async {
      final file = File('${tempDir.path}/sync_multi_rx.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '7777',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_alpha',
        deviceName: 'Receiver Alpha',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_beta',
        deviceName: 'Receiver Beta',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Alpha is at 80%, Beta is at 20%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_alpha',
        'percent': 80.0,
        'bytesTransferred': 80 * 1024,
      });

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_beta',
        'percent': 20.0,
        'bytesTransferred': 20 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      // Aggregate overall delivery progress is (80 + 20) / 2 = 50.0%
      expect(snap.progressPercent, 50.0);
      expect(snap.bytesTransferred, 50 * 1024);

      // Individual receiver progress remains strictly truthful and separate
      expect(snap.receiverProgressMap['rx_alpha'], 80.0);
      expect(snap.receiverProgressMap['rx_beta'], 20.0);
      expect(snap.isCompleted, isFalse);
    });

    test('8. Multiple files use consistent batch-level totals', () async {
      // 2 files in batch: 100 KB + 300 KB = 400 KB total
      final file1 = File('${tempDir.path}/batch_file_1.bin');
      await file1.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final m1 = await ManifestService.createManifest(file1, chunkSize: 32 * 1024);

      final file2 = File('${tempDir.path}/batch_file_2.bin');
      await file2.writeAsBytes(List.generate(300 * 1024, (i) => (i * 3) % 256));
      final m2 = await ManifestService.createManifest(file2, chunkSize: 32 * 1024);

      final batchManifest = BatchManifest(
        batchId: 'batch_multi_file_sync',
        manifests: [m1, m2],
      );

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '8888',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_batch',
        deviceName: 'Receiver Batch',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Receiver completes file 1 (100 KB) and 100 KB of file 2 (200 KB total out of 400 KB = 50%)
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': 'batch_multi_file_sync',
        'peerId': 'rx_batch',
        'percent': 50.0,
        'bytesTransferred': 200 * 1024,
        'totalBytes': 400 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.totalBytes, 400 * 1024);
      expect(snap.bytesTransferred, 200 * 1024);
      expect(snap.progressPercent, 50.0);
    });

    test('9. Neither side displays 100% before genuine completion', () async {
      final file = File('${tempDir.path}/sync_not_done.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 32 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      server.setBatchManifests([(manifest: manifest, file: file)]);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '9999',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_not_done',
        deviceName: 'Receiver Not Done',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // All chunks served via HTTP
      for (int c = 0; c < manifest.chunkCount; c++) {
        final url = Uri.parse('http://127.0.0.1:$serverPort/file/${manifest.fileId}/chunk/$c');
        final res = await http.get(url, headers: {'X-Peer-Id': 'rx_not_done'});
        expect(res.statusCode, 200);
      }

      await Future.delayed(const Duration(milliseconds: 50));

      // Server served 100% of chunks over HTTP, but receiver has NOT confirmed commit!
      // Must NOT show 100% and must NOT be completed!
      final snap = sessionManager.currentSnapshot!;
      expect(snap.isCompleted, isFalse, reason: 'Session must NOT complete simply because bytes were served');
      expect(snap.progressPercent, 0.0);
    });

    test('10. Failed and cancelled transfers do not become completed', () async {
      final file = File('${tempDir.path}/sync_fail_test.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1010',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_fail',
        deviceName: 'Receiver Fail',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Receiver reports 50%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_fail',
        'percent': 50.0,
        'bytesTransferred': 50 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));

      // Receiver fails
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_fail',
        deviceName: 'Receiver Fail',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.failed,
        errorMessage: 'Disk I/O error',
        lastSeen: DateTime.now(),
      ));
      server.notifyControlListenersForTesting({
        'type': 'RECEIVER_FAILED',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_fail',
        'error': 'Disk I/O error',
      });
      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.isCompleted, isFalse);
      expect(snap.isFailed, isTrue);

      // Cancel transfer
      await sessionManager.cancel();
      expect(sessionManager.currentSnapshot!.isCancelled, isTrue);
      expect(sessionManager.currentSnapshot!.isCompleted, isFalse);
    });

    test('11. Final completion produces 100% on both screens', () async {
      final file = File('${tempDir.path}/sync_complete.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1212',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_complete',
        deviceName: 'Receiver Complete',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Advance to 100%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_complete',
        'percent': 100.0,
        'bytesTransferred': 100 * 1024,
        'totalBytes': 100 * 1024,
      });

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_COMPLETED',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_complete',
      });

      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.progressPercent, 100.0);
      expect(snap.bytesTransferred, 100 * 1024);
      expect(snap.isCompleted, isTrue);
    });

    test('12. Any new confirmation mechanism handles missing, delayed, or invalid updates safely', () async {
      final file = File('${tempDir.path}/sync_robustness.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1313',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_robust',
        deviceName: 'Receiver Robust',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // 12a: Send NaN, infinite, and negative percentages -> all safely rejected
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_robust',
        'percent': double.nan,
      });
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_robust',
        'percent': double.infinity,
      });
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_robust',
        'percent': -10.0,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 0.0);

      // 12b: Test HTTP POST /transfer/progress confirmation fallback endpoint
      final progressUrl = Uri.parse('http://127.0.0.1:$serverPort/transfer/progress');
      final resProg = await http.post(
        progressUrl,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'sessionId': batchManifest.batchId,
          'peerId': 'rx_robust',
          'percent': 65.0,
          'bytesTransferred': 65 * 1024,
          'totalBytes': 100 * 1024,
        }),
      );
      expect(resProg.statusCode, 200);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 65.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 65 * 1024);

      // 12c: Test HTTP POST /transfer/completed confirmation fallback endpoint
      final completedUrl = Uri.parse('http://127.0.0.1:$serverPort/transfer/completed');
      final resComp = await http.post(
        completedUrl,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'sessionId': batchManifest.batchId,
          'peerId': 'rx_robust',
        }),
      );
      expect(resComp.statusCode, 200);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.isCompleted, isTrue);
      expect(sessionManager.currentSnapshot!.progressPercent, 100.0);
    });
  });
}
