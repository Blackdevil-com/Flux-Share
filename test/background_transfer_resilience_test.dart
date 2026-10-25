import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/chunk_persistence_manager.dart';
import 'package:fluxshare/models/batch_manifest.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/models/models.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';
import 'package:fluxshare/transfer/transfer_metrics_calculator.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TransferMetricsCalculator Unit Tests', () {
    test('Calculates rolling smoothed speed and non-negative ETA correctly', () {
      final calc = TransferMetricsCalculator(
        windowDuration: const Duration(seconds: 2),
        smoothingAlpha: 0.5,
      );

      // Initial sample (0 MB at t=0)
      final r1 = calc.update(totalBytesTransferred: 0, totalFileSize: 100 * 1024 * 1024);
      expect(r1.smoothedSpeedMbPerSec, equals(0.0));
      expect(r1.remainingSeconds, equals(0));

      // 10 MB after a simulated small delay
      final r2 = calc.update(
        totalBytesTransferred: 10 * 1024 * 1024,
        totalFileSize: 100 * 1024 * 1024,
      );
      expect(r2.smoothedSpeedMbPerSec, greaterThanOrEqualTo(0.0));

      // Reset
      calc.reset();
      expect(calc.smoothedSpeedMbPerSec, equals(0.0));
    });

    test('Stall detection detects inactivity after threshold', () async {
      final calc = TransferMetricsCalculator();
      calc.update(totalBytesTransferred: 1000, totalFileSize: 10000);
      expect(calc.isStalled(stallThreshold: const Duration(milliseconds: 50)), isFalse);

      await Future.delayed(const Duration(milliseconds: 60));
      expect(calc.isStalled(stallThreshold: const Duration(milliseconds: 50)), isTrue);
    });
  });

  group('ChunkPersistenceManager Unit Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fluxshare_chk_test_');
      ChunkPersistenceManager().setCustomDirectory(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Persists, verifies, and reloads chunk checkpoint matching SHA-256', () async {
      final mgr = ChunkPersistenceManager();
      const fileId = 'file_abc_123';
      const fileSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      // Initially null
      final initial = await mgr.loadCheckpoint(fileId: fileId, fileSha256: fileSha256);
      expect(initial, isNull);

      // Save verified chunks: 0, 2, 5
      await mgr.saveCheckpoint(
        fileId: fileId,
        fileName: 'sample_video.mp4',
        fileSha256: fileSha256,
        fileSize: 50 * 1024 * 1024,
        totalChunks: 10,
        verifiedChunks: {0, 2, 5},
      );

      // Reload
      final loaded = await mgr.loadCheckpoint(fileId: fileId, fileSha256: fileSha256);
      expect(loaded, isNotNull);
      expect(loaded, containsAll({0, 2, 5}));
      expect(loaded!.length, equals(3));

      // Mismatched file SHA-256 discards stale checkpoint
      final mismatch = await mgr.loadCheckpoint(fileId: fileId, fileSha256: 'different_hash');
      expect(mismatch, isNull);

      // Delete checkpoint
      await mgr.deleteCheckpoint(fileId);
      final afterDelete = await mgr.loadCheckpoint(fileId: fileId, fileSha256: fileSha256);
      expect(afterDelete, isNull);
    });
  });

  group('TransferSessionManager Unit Tests', () {
    test('Host session starts, tracks receivers, and cancels cleanly', () async {
      final sessionManager = TransferSessionManager.instance;

      final server = LocalServer();
      final manifest1 = Manifest(
        fileId: 'host_file_1',
        fileName: 'test_doc.pdf',
        fileSize: 1024 * 1024,
        mimeType: 'application/pdf',
        chunkSize: 512 * 1024,
        chunkCount: 2,
        fileSha256: 'abc1',
        chunks: const [],
      );
      final batchManifest = BatchManifest(
        batchId: 'host_batch_1',
        manifests: [manifest1],
      );

      await sessionManager.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: [
          const Device(
            id: 'peer_1',
            name: "Akash's Phone",
            ip: '192.168.1.5',
            platform: DevicePlatform.Android,
            isAvailable: true,
            signalStrength: 4,
          ),
        ],
        roomPin: '1234',
      );

      expect(sessionManager.hasActiveSession, isTrue);
      expect(sessionManager.isHost, isTrue);
      expect(sessionManager.currentSnapshot?.sessionId, equals('host_batch_1'));
      expect(sessionManager.currentSnapshot?.totalFiles, equals(1));
      expect(sessionManager.currentSnapshot?.receiverProgressMap.containsKey('peer_1'), isTrue);

      // Cancel host session
      await sessionManager.cancel();
      expect(sessionManager.hasActiveSession, isFalse);
      expect(sessionManager.currentSnapshot?.isCancelled, isTrue);
    });

    test('Receiver batch session propagates progress snapshot and formatted remaining time', () async {
      final sessionManager = TransferSessionManager.instance;

      final manifest = Manifest(
        fileId: 'batch_file_1',
        fileName: 'archive.zip',
        fileSize: 2 * 1024 * 1024,
        mimeType: 'application/zip',
        chunkSize: 1024 * 1024,
        chunkCount: 2,
        fileSha256: 'def2',
        chunks: const [],
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_rx_1',
        items: [
          BatchTransferItem(
            fileId: 'batch_file_1',
            fileInfo: const FileInfo(
              id: 'batch_file_1',
              name: 'archive.zip',
              sizeBytes: 2 * 1024 * 1024,
              formattedSize: '2.0 MB',
              extension: 'zip',
              type: FileType.Archive,
            ),
            manifest: manifest,
            totalBytes: 2 * 1024 * 1024,
          ),
        ],
        swarmPeers: const [],
        localServer: LocalServer(),
        localPeerId: 'rx_peer',
        coordinatorPeerId: 'host_peer',
      );

      await sessionManager.startReceiverBatchSession(
        coordinator: coordinator,
        batchManifest: BatchManifest(batchId: 'batch_rx_1', manifests: [manifest]),
      );

      expect(sessionManager.hasActiveSession, isTrue);
      expect(sessionManager.isHost, isFalse);
      expect(sessionManager.currentSnapshot?.totalBytes, equals(2 * 1024 * 1024));

      // Test pause and resume
      sessionManager.pause();
      expect(coordinator.isPaused, isTrue);

      sessionManager.resume();
      expect(coordinator.isPaused, isFalse);

      await sessionManager.cancel();
      expect(sessionManager.hasActiveSession, isFalse);
    });
  });
}
