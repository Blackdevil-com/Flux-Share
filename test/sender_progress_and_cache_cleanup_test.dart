import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/models.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/services/managed_temporary_file_service.dart';
import 'package:fluxshare/services/storage_diagnostics_service.dart';
import 'package:fluxshare/services/storage_path_service.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory managedTempDir;
  late LocalServer server;

  setUp(() async {
    HttpOverrides.global = null;
    NetworkUtils.customLocalIp = '127.0.0.1';

    tempDir = await Directory.systemTemp.createTemp('fluxshare_sender_test_');
    managedTempDir = Directory('${tempDir.path}/managed_tmp');
    await managedTempDir.create(recursive: true);
    ManagedTemporaryFileService.customManagedTempDir = managedTempDir;
    ManagedTemporaryFileService.instance.resetForTesting();

    StoragePathService.customSaveDirectory = Directory('${tempDir.path}/Downloads');
    await StoragePathService.customSaveDirectory!.create(recursive: true);

    server = LocalServer();
    await server.start(preferredPort: 19892);
    server.clearReceivers();
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    StoragePathService.customSaveDirectory = null;
    ManagedTemporaryFileService.customManagedTempDir = null;
    ManagedTemporaryFileService.instance.resetForTesting();

    server.clearBatch();
    await server.stop();

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Part A: Sender-side Progress Aggregation Tests', () {
    test('1. One receiver progresses from 0% to 100% cleanly', () async {
      final file = File('${tempDir.path}/file_1.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1111',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_1',
        deviceName: 'Receiver 1',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      expect(sessionManager.currentSnapshot!.progressPercent, 0.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 0);

      // Progress to 50%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_1',
        'percent': 50.0,
        'bytesTransferred': 50 * 1024,
        'speedMbPerSec': 5.0,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 50.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 50 * 1024);

      // Complete to 100%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_1',
        'percent': 100.0,
        'bytesTransferred': 100 * 1024,
        'speedMbPerSec': 5.0,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 100.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 100 * 1024);
      expect(sessionManager.currentSnapshot!.isCompleted, isTrue);
    });

    test('2. Delayed lower-progress update does NOT regress progress', () async {
      final file = File('${tempDir.path}/file_2.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
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
        peerId: 'rx_mono',
        deviceName: 'Receiver Mono',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Advance to 75%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_mono',
        'percent': 75.0,
        'bytesTransferred': 75 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 75.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 75 * 1024);

      // Stale out-of-order update arrives with 50%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_mono',
        'percent': 50.0,
        'bytesTransferred': 50 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));

      // Progress MUST remain at 75% without regression
      expect(sessionManager.currentSnapshot!.progressPercent, 75.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 75 * 1024);
    });

    test('3. Duplicate progress messages arrive idempotently without fluctuation', () async {
      final file = File('${tempDir.path}/file_dup.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '3333',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_dup',
        deviceName: 'Receiver Dup',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Send identical update 3 times
      for (int i = 0; i < 3; i++) {
        server.notifyControlListenersForTesting({
          'type': 'TRANSFER_PROGRESS',
          'sessionId': batchManifest.batchId,
          'peerId': 'rx_dup',
          'percent': 60.0,
          'bytesTransferred': 60 * 1024,
        });
      }

      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 60.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 60 * 1024);
    });

    test('4. Two receivers progress at different rates with truthful individual progress', () async {
      final file = File('${tempDir.path}/file_multi.bin');
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
        peerId: 'rx_a',
        deviceName: 'Device A',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_b',
        deviceName: 'Device B',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Rx A at 80%, Rx B at 20%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_a',
        'percent': 80.0,
        'bytesTransferred': 80 * 1024,
      });

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_b',
        'percent': 20.0,
        'bytesTransferred': 20 * 1024,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      // Aggregate displayed progress is (80 + 20) / 2 = 50%
      expect(snap.progressPercent, 50.0);
      expect(snap.bytesTransferred, 50 * 1024);

      // Individual receiver progress remains completely truthful
      expect(snap.receiverProgressMap['rx_a'], 80.0);
      expect(snap.receiverProgressMap['rx_b'], 20.0);
      expect(snap.isCompleted, isFalse);
    });

    test('5. A second receiver joins while the first is progressing without backward progress jump', () async {
      final file = File('${tempDir.path}/file_late.bin');
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

      // Rx 1 connects and reaches 80%
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_first',
        deviceName: 'First Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_first',
        'percent': 80.0,
        'bytesTransferred': 80 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 80.0);

      // Late receiver joins at 0%
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_late',
        deviceName: 'Late Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      // Displayed progress must NOT jump backwards to 40%! It remains at 80%
      final snap = sessionManager.currentSnapshot!;
      expect(snap.progressPercent, 80.0, reason: 'Aggregate displayed percentage must not jump backwards on late join');
      expect(snap.bytesTransferred, 80 * 1024);

      // Individual receiver progress remains truthful (late receiver is at 0%)
      expect(snap.receiverProgressMap['rx_late'], 0.0);
      expect(snap.receiverProgressMap['rx_first'], 80.0);
      expect(snap.isCompleted, isFalse);
    });

    test('6. Receiver disconnect and reconnect preserves progress', () async {
      final file = File('${tempDir.path}/file_reconnect.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '6666',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_rec',
        deviceName: 'Disconnecting Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_rec',
        'percent': 45.0,
        'bytesTransferred': 45 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 45.0);

      // Receiver status changes to disconnected
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_rec',
        deviceName: 'Disconnecting Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.disconnected,
        progressPercent: 45.0,
        bytesReceived: 45 * 1024,
        lastSeen: DateTime.now(),
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 45.0);

      // Reconnects
      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_rec',
        deviceName: 'Disconnecting Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.receiving,
        progressPercent: 45.0,
        bytesReceived: 45 * 1024,
        lastSeen: DateTime.now(),
      ));
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 45.0);
      expect(sessionManager.currentSnapshot!.isCompleted, isFalse);
    });

    test('7. Out-of-range, NaN, or negative progress values are clamped/filtered safely', () async {
      final file = File('${tempDir.path}/file_invalid.bin');
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
        peerId: 'rx_inv',
        deviceName: 'Receiver Invalid',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Negative value
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_inv',
        'percent': -50.0,
        'bytesTransferred': -1000,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 0.0);

      // Value greater than 100%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_inv',
        'percent': 150.0,
        'bytesTransferred': 500 * 1024, // file is only 100 KB
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 100.0);
      expect(sessionManager.currentSnapshot!.bytesTransferred, 100 * 1024);
    });

    test('8. Speed calculation and ETA calculation are consistent with progress', () async {
      final file = File('${tempDir.path}/file_speed.bin');
      await file.writeAsBytes(List.generate(1000 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '8888',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_spd',
        deviceName: 'Receiver Speed',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // When bytes do not change, speed decays and does not spike
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_spd',
        'percent': 50.0,
        'bytesTransferred': 500 * 1024,
        'speedMbPerSec': 10.0,
      });
      await Future.delayed(const Duration(milliseconds: 50));

      final snap = sessionManager.currentSnapshot!;
      expect(snap.progressPercent, 50.0);
      expect(snap.bytesTransferred, 500 * 1024);
      expect(snap.speedMbPerSec, 10.0);
      // Remaining bytes: 500 KB at 10 MB/s = ~1 sec ETA
      expect(snap.remainingSeconds, greaterThanOrEqualTo(0));
    });

    test('9. A new session resets the old session progress and speed history', () async {
      final file = File('${tempDir.path}/file_session.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest1 = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest1,
        receivers: [],
        roomPin: '9991',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_reset',
        deviceName: 'Receiver Reset',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest1.batchId,
        'peerId': 'rx_reset',
        'percent': 90.0,
        'bytesTransferred': 90 * 1024,
        'speedMbPerSec': 15.0,
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(sessionManager.currentSnapshot!.progressPercent, 90.0);

      // Start new session
      final batchManifest2 = BatchManifest.fromSingleManifest(manifest);
      server.clearReceivers();
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest2,
        receivers: [],
        roomPin: '9992',
      );

      // Progress and speed MUST be completely reset to 0
      final newSnap = sessionManager.currentSnapshot!;
      expect(newSnap.progressPercent, 0.0);
      expect(newSnap.bytesTransferred, 0);
      expect(newSnap.speedMbPerSec, 0.0);
      expect(newSnap.isCompleted, isFalse);
    });

    test('10. Completion is based on valid transfer state, not merely display percentage', () async {
      final file = File('${tempDir.path}/file_state.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      const expectedDevice = Device(
        id: 'device_req',
        name: 'Required Device',
        platform: DevicePlatform.Android,
        isAvailable: true,
        signalStrength: 4,
        ip: '127.0.0.1',
      );

      // Start session with expected pre-selected device
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [expectedDevice],
        roomPin: '1010',
      );

      // Another un-selected receiver joins and reaches 100%
      server.updateReceiver(ConnectedReceiver(
        peerId: 'unselected_rx',
        deviceName: 'Unselected',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.completed,
        progressPercent: 100.0,
        bytesReceived: 100 * 1024,
        lastSeen: DateTime.now(),
      ));

      await Future.delayed(const Duration(milliseconds: 50));
      // Required device has NOT completed, so session MUST NOT complete
      expect(sessionManager.currentSnapshot!.isCompleted, isFalse);
    });

    test('11. Completion snapshot is emitted cleanly once without multiple triggers', () async {
      final file = File('${tempDir.path}/file_once.bin');
      await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));
      final manifest = await ManifestService.createManifest(file, chunkSize: 64 * 1024);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '1111',
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_once',
        deviceName: 'Receiver Once',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      int completedSnapshots = 0;
      final sub = sessionManager.progressStream.listen((snap) {
        if (snap.status == TransferStatus.completed) {
          completedSnapshots++;
        }
      });

      // Send 100% progress
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_once',
        'percent': 100.0,
        'bytesTransferred': 100 * 1024,
      });
      await Future.delayed(const Duration(milliseconds: 50));

      // Send duplicate TRANSFER_COMPLETED
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_COMPLETED',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_once',
      });
      await Future.delayed(const Duration(milliseconds: 50));

      expect(sessionManager.currentSnapshot!.isCompleted, isTrue);
      expect(completedSnapshots, 1, reason: 'Completed snapshot must be emitted exactly once');
      await sub.cancel();
    });
  });

  group('Part B: Sender-side Temporary Cache Cleanup Tests', () {
    test('1. Successful transfer removes session-owned temporary files', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_success_1';

      // Create managed temporary copy (content URI simulation)
      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_temp_1',
        name: 'temp_video.mp4',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );

      expect(ref.isManaged, isTrue);
      expect(await ref.file.exists(), isTrue);

      final freed = await service.cleanupSession(sessionId, reason: 'host_transfer_completed');
      expect(freed, 1024);
      expect(await ref.file.exists(), isFalse, reason: 'Managed temp file must be deleted on completion');
    });

    test('2. Original selected user files are strictly preserved', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_orig_2';

      final originalUserFile = File('${tempDir.path}/MyDocument.pdf');
      await originalUserFile.writeAsBytes(List.generate(2048, (i) => i % 256));

      // Register original file with filesystem path
      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_orig_2',
        name: 'MyDocument.pdf',
        sizeBytes: 2048,
        path: originalUserFile.path,
      );

      expect(ref.isManaged, isFalse);
      expect(await originalUserFile.exists(), isTrue);

      // Cleanup
      final freed = await service.cleanupSession(sessionId, reason: 'host_transfer_completed');
      expect(freed, 0);
      expect(await originalUserFile.exists(), isTrue, reason: 'User original file must NEVER be deleted');
    });

    test('3. Multi-receiver: completed receiver does NOT trigger cleanup while other receivers transfer', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_multi_rx';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_multi_3',
        name: 'shared_data.bin',
        sizeBytes: 512,
        bytes: Uint8List(512),
      );
      expect(await ref.file.exists(), isTrue);

      // Transfer session with 2 receivers
      final file = ref.file;
      final manifest = await ManifestService.createManifest(file, chunkSize: 256);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '3333',
        sessionId: sessionId,
      );

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_first_done',
        deviceName: 'Done Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      server.updateReceiver(ConnectedReceiver(
        peerId: 'rx_still_working',
        deviceName: 'Working Receiver',
        platform: DevicePlatform.Android,
        ip: '127.0.0.1',
        status: ReceiverStatus.connected,
        lastSeen: DateTime.now(),
      ));

      // Receiver 1 finishes 100%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_first_done',
        'percent': 100.0,
        'bytesTransferred': 512,
      });

      // Receiver 2 is at 40%
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_still_working',
        'percent': 40.0,
        'bytesTransferred': 200,
      });

      await Future.delayed(const Duration(milliseconds: 50));

      // Session must NOT be completed and temp file MUST NOT be deleted
      expect(sessionManager.currentSnapshot!.isCompleted, isFalse);
      expect(await ref.file.exists(), isTrue, reason: 'Shared temporary file must remain while any receiver transfers');

      // Now Receiver 2 finishes
      server.notifyControlListenersForTesting({
        'type': 'TRANSFER_PROGRESS',
        'sessionId': batchManifest.batchId,
        'peerId': 'rx_still_working',
        'percent': 100.0,
        'bytesTransferred': 512,
      });

      await Future.delayed(const Duration(milliseconds: 100));

      expect(sessionManager.currentSnapshot!.isCompleted, isTrue);
      expect(await ref.file.exists(), isFalse, reason: 'Temporary file deleted after ALL receivers finish');
    });

    test('4. Explicit cancellation cleans up disposable temporary files', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_cancel_4';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_cancel_4',
        name: 'cancel_file.bin',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );

      final manifest = await ManifestService.createManifest(ref.file, chunkSize: 256);
      final batchManifest = BatchManifest.fromSingleManifest(manifest);

      final sessionManager = TransferSessionManager.instance;
      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [],
        roomPin: '4444',
        sessionId: sessionId,
      );

      expect(await ref.file.exists(), isTrue);

      await sessionManager.cancel();

      expect(sessionManager.currentSnapshot!.isCancelled, isTrue);
      expect(await ref.file.exists(), isFalse, reason: 'Cancellation must safely delete session temp file');
    });

    test('5. Cleanup for one session does NOT remove another active session files', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionA = 'session_alpha';
      const sessionB = 'session_beta';

      final refA = await service.getOrCreateManagedCopy(
        sessionId: sessionA,
        fileId: 'file_a',
        name: 'alpha.tmp',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );

      final refB = await service.getOrCreateManagedCopy(
        sessionId: sessionB,
        fileId: 'file_b',
        name: 'beta.tmp',
        sizeBytes: 2048,
        bytes: Uint8List(2048),
      );

      expect(await refA.file.exists(), isTrue);
      expect(await refB.file.exists(), isTrue);

      // Clean up session A
      await service.cleanupSession(sessionA, reason: 'session_a_done');

      expect(await refA.file.exists(), isFalse);
      expect(await refB.file.exists(), isTrue, reason: 'Session B file must remain untouched');

      // Now clean up session B
      await service.cleanupSession(sessionB, reason: 'session_b_done');
      expect(await refB.file.exists(), isFalse);
    });

    test('6. Shared file aliased between sessions is retained until all referencing sessions end', () async {
      final service = ManagedTemporaryFileService.instance;
      const session1 = 'session_shared_1';
      const session2 = 'session_shared_2';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: session1,
        fileId: 'shared_file',
        name: 'shared.tmp',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );

      // Alias to session 2
      service.aliasSession(sourceSessionId: session1, targetSessionId: session2);

      expect(await ref.file.exists(), isTrue);

      // Clean up session 1 while session 2 still references it
      await service.cleanupSession(session1, reason: 'session_1_ended');

      // Must be retained because session 2 still references it
      expect(await ref.file.exists(), isTrue, reason: 'File referenced by session 2 must not be deleted by session 1');

      // Now clean up session 2
      await service.cleanupSession(session2, reason: 'session_2_ended');
      expect(await ref.file.exists(), isFalse, reason: 'File deleted when all referencing sessions end');
    });

    test('7. Active reader count prevents premature deletion during chunk streaming', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_active_read';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_read',
        name: 'active_read.tmp',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );

      // Simulate active HTTP reader streaming a chunk
      service.registerActiveUse(sessionId, ref.path);
      expect(ref.activeReaderCount, 1);

      // Attempt cleanup while reader is active
      await service.cleanupSession(sessionId, reason: 'completed_while_streaming');

      // File must be marked for deferred deletion, NOT deleted immediately
      expect(ref.markedForDeletion, isTrue);
      expect(await ref.file.exists(), isTrue, reason: 'File in active read must not be deleted out from under stream');

      // Stream finishes
      await service.releaseActiveUse(sessionId, ref.path);

      // File is deleted safely after reader release
      expect(await ref.file.exists(), isFalse, reason: 'File deleted automatically when reader count reached 0');
    });

    test('8. Missing files and repeated cleanup calls are handled safely and idempotently', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_idempotent';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_idem',
        name: 'idem.tmp',
        sizeBytes: 512,
        bytes: Uint8List(512),
      );
      expect(await ref.file.exists(), isTrue);

      // Call cleanup once
      final freed1 = await service.cleanupSession(sessionId, reason: 'first_call');
      expect(freed1, 512);

      // Call cleanup a second time on the same session
      final freed2 = await service.cleanupSession(sessionId, reason: 'second_call');
      expect(freed2, 0, reason: 'Repeated cleanup call must be safe and idempotent');

      // Call cleanup a third time on a nonexistent session
      final freed3 = await service.cleanupSession('nonexistent_session', reason: 'third_call');
      expect(freed3, 0);
    });

    test('9. Startup orphan cleanup cleans stale files and preserves active files', () async {
      final service = ManagedTemporaryFileService.instance;

      // Create an old stale temporary file directly in managed temp dir
      final staleFile = File('${managedTempDir.path}/fs_managed_old_crashed_file.tmp');
      await staleFile.writeAsBytes(Uint8List(2048));

      // Create a staging file .part
      final stagingPartFile = File('${managedTempDir.path}/fs_managed_abandoned_upload.part');
      await stagingPartFile.writeAsBytes(Uint8List(512));

      // Create an unrelated user file in the directory (should never be touched)
      final userUnrelatedFile = File('${managedTempDir.path}/unrelated_photo.jpg');
      await userUnrelatedFile.writeAsBytes(Uint8List(4096));

      // Run cleanup with maxAge: 0 seconds to simulate startup after crash
      final freed = await service.cleanupStaleSessions(
        maxAge: Duration.zero,
        customDir: managedTempDir,
      );

      expect(freed, 2048 + 512);
      expect(await staleFile.exists(), isFalse, reason: 'Stale managed temp file must be cleaned up');
      expect(await stagingPartFile.exists(), isFalse, reason: 'Abandoned staging .part file must be cleaned up');
      expect(await userUnrelatedFile.exists(), isTrue, reason: 'Files without managed prefix must NEVER be touched');
    });

    test('10. Transfer failure safely triggers temporary cache cleanup', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_failed_1';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_fail_temp',
        name: 'failed_upload.tmp',
        sizeBytes: 1024,
        bytes: Uint8List(1024),
      );
      expect(await ref.file.exists(), isTrue);

      // Session fails or is aborted due to network failure
      final freed = await service.cleanupSession(sessionId, reason: 'transfer_failed');
      expect(freed, 1024);
      expect(await ref.file.exists(), isFalse);
    });

    test('11. StorageDiagnosticsService tracks temp files and reflects accurate freed bytes', () async {
      final service = ManagedTemporaryFileService.instance;
      const sessionId = 'session_diag_1';

      final ref = await service.getOrCreateManagedCopy(
        sessionId: sessionId,
        fileId: 'file_diag_1',
        name: 'diag_file.tmp',
        sizeBytes: 2048,
        bytes: Uint8List(2048),
      );

      final diag = StorageDiagnosticsService();
      expect(diag.activeTempFiles.contains(ref.path), isTrue);

      final freed = await service.cleanupSession(sessionId, reason: 'test_diag_cleanup');
      expect(freed, 2048);
      expect(await ref.file.exists(), isFalse);
      expect(diag.activeTempFiles.contains(ref.path), isFalse);
    });
  });
}
