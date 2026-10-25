import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/batch_manifest.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/transfer.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/repositories/transfer_repository.dart';
import 'package:fluxshare/transfer/batch_transfer_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer localServer;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_batch_coordinator_test_');
    localServer = LocalServer();
    await localServer.start();
  });

  tearDown(() async {
    await localServer.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('BatchTransferCoordinator Unit Tests', () {
    test('Calculates mathematically accurate byte-weighted overall progress', () async {
      final file1 = File('${tempDir.path}/tmp1.bin')..writeAsBytesSync(List.filled(9000, 1));
      final file2 = File('${tempDir.path}/tmp2.bin')..writeAsBytesSync(List.filled(1000, 2));

      final m1 = await ManifestService.createManifest(file1, chunkSize: 2048);
      final m2 = await ManifestService.createManifest(file2, chunkSize: 1024);

      final fileInfo1 = await FileInfo.fromFile(file1);
      final fileInfo2 = await FileInfo.fromFile(file2);

      final item1 = BatchTransferItem(
        fileId: 'f1',
        fileInfo: fileInfo1,
        manifest: m1,
        totalBytes: 9000,
      );

      final item2 = BatchTransferItem(
        fileId: 'f2',
        fileInfo: fileInfo2,
        manifest: m2,
        totalBytes: 1000,
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_test',
        items: [item1, item2],
        swarmPeers: [],
        localServer: localServer,
        localPeerId: 'local_test',
        coordinatorPeerId: 'host_test',
      );

      // Total bytes = 10,000
      expect(coordinator.totalBytes, equals(10000));

      // Scenario: item2 (1000 bytes) is 100% complete (1000 bytes transferred),
      // item1 (9000 bytes) is 0% complete (0 bytes transferred).
      item2.bytesTransferred = 1000;
      item2.progressPercent = 100.0;
      item1.bytesTransferred = 0;
      item1.progressPercent = 0.0;

      // Arithmetic average would be: (0% + 100%) / 2 = 50.0% (WRONG)
      // Byte-weighted progress is: (0 + 1000) / 10000 = 10.0% (CORRECT)
      expect(coordinator.overallProgressPercent, closeTo(10.0, 0.01));

      // Scenario: item1 transfers 4500 bytes (50% of heavy file)
      item1.bytesTransferred = 4500;
      // Byte-weighted: (4500 + 1000) / 10000 = 55.0%
      expect(coordinator.overallProgressPercent, closeTo(55.0, 0.01));
    });

    test('Handles empty files and zero-byte totals safely without division-by-zero errors', () async {
      final emptyFile = File('${tempDir.path}/empty.txt')..writeAsStringSync('');
      final emptyManifest = await ManifestService.createManifest(emptyFile);

      final itemZero = BatchTransferItem(
        fileId: 'zero_file',
        fileInfo: const FileInfo(
          id: 'zero_file',
          name: 'empty.txt',
          sizeBytes: 0,
          formattedSize: '0 B',
          extension: 'txt',
          type: FileType.Document,
        ),
        manifest: emptyManifest,
        totalBytes: 0,
      );

      final coordinator = BatchTransferCoordinator(
        batchId: 'batch_zero',
        items: [itemZero],
        swarmPeers: [],
        localServer: localServer,
        localPeerId: 'local_test',
        coordinatorPeerId: 'host_test',
      );

      expect(coordinator.totalBytes, equals(0));
      // Not completed yet -> 0.0%
      expect(coordinator.overallProgressPercent, equals(0.0));

      // Mark completed -> 100.0%
      itemZero.status = TransferStatus.completed;
      expect(coordinator.overallProgressPercent, equals(100.0));
    });

    test('BatchManifest serializes and deserializes multiple manifests accurately', () async {
      final f1 = File('${tempDir.path}/file1.txt')..writeAsStringSync('First file content');
      final f2 = File('${tempDir.path}/file2.txt')..writeAsStringSync('Second file content longer');

      final m1 = await ManifestService.createManifest(f1);
      final m2 = await ManifestService.createManifest(f2);

      final batch = BatchManifest(
        batchId: 'batch_123',
        manifests: [m1, m2],
      );

      expect(batch.totalFiles, equals(2));
      expect(batch.totalBytes, equals(m1.fileSize + m2.fileSize));

      final json = batch.toJson();
      final restored = BatchManifest.fromJson(json);

      expect(restored.batchId, equals('batch_123'));
      expect(restored.totalFiles, equals(2));
      expect(restored.totalBytes, equals(batch.totalBytes));
      expect(restored.manifests[0].fileName, equals(m1.fileName));
      expect(restored.manifests[1].fileName, equals(m2.fileName));
      expect(restored.findManifest(m1.fileId)?.fileSha256, equals(m1.fileSha256));
    });

    test('Records independent history entries in TransferRepository for each file in a batch', () async {
      final repo = TransferRepository();
      await repo.init();

      const f1Info = FileInfo(
        id: 'f_history_1',
        name: 'report1.pdf',
        sizeBytes: 1024,
        formattedSize: '1 KB',
        extension: 'pdf',
        type: FileType.Document,
      );
      const f2Info = FileInfo(
        id: 'f_history_2',
        name: 'video2.mp4',
        sizeBytes: 4096,
        formattedSize: '4 KB',
        extension: 'mp4',
        type: FileType.Video,
      );

      final record1 = Transfer(
        id: 'f_history_1',
        fileInfo: f1Info,
        direction: TransferDirection.sent,
        status: TransferStatus.completed,
        progressPercent: 100.0,
        bytesTransferred: 1024,
        transferSpeedMbPerSec: 12.5,
        remainingSeconds: 0,
        timestamp: DateTime.now(),
        receivers: [],
        chunkStats: {'batchId': 'batch_xyz'},
      );

      final record2 = Transfer(
        id: 'f_history_2',
        fileInfo: f2Info,
        direction: TransferDirection.sent,
        status: TransferStatus.failed,
        progressPercent: 30.0,
        bytesTransferred: 1200,
        transferSpeedMbPerSec: 5.0,
        remainingSeconds: 10,
        timestamp: DateTime.now(),
        receivers: [],
        chunkStats: {'batchId': 'batch_xyz'},
      );

      repo.updateTransfer(record1);
      repo.updateTransfer(record2);

      final history = await repo.getTransferHistory();
      final hasF1 = history.any((t) => t.id == 'f_history_1' && t.status == TransferStatus.completed);
      final hasF2 = history.any((t) => t.id == 'f_history_2' && t.status == TransferStatus.failed);

      expect(hasF1, isTrue);
      expect(hasF2, isTrue);
    });
  });
}
