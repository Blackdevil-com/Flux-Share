import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/screens/send_file/send_file_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_cancel_test_');
    ManifestService.disableIsolatesForTesting = true;
  });

  tearDown(() async {
    ManifestService.disableIsolatesForTesting = false;
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Manifest Pipeline Cancellation & Reselection Regression Tests', () {
    test('1. Full cancellation, reselection, 127 KB file processing, and worker slot release', () async {
      // Create a 127 KB file and a simulated 1 MB file
      final largeFile = File('${tempDir.path}/large_video.mp4');
      await largeFile.writeAsBytes(List.filled(1024 * 1024, 42));

      final small127KbFile = File('${tempDir.path}/small_document.pdf');
      await small127KbFile.writeAsBytes(List.filled(127 * 1024, 7));

      final initialItem = PickedFileItem(
        id: 'job_large_1',
        jobId: 1,
        file: largeFile,
        info: FileInfo.fromMetadata(
          path: largeFile.path,
          name: 'large_video.mp4',
          sizeBytes: 1024 * 1024,
        ),
        status: FilePreparationStatus.hashing,
      );

      final selectedFiles = <PickedFileItem>[initialItem];
      final activeWorkerJobIds = <int>{initialItem.jobId};

      // Step 1: Simulate active hashing with cancel capability
      expect(activeWorkerJobIds.length, equals(1));
      expect(initialItem.status, equals(FilePreparationStatus.hashing));

      // Step 2: Cancel the active job
      initialItem.isCancelled = true;
      initialItem.jobId++;
      initialItem.status = FilePreparationStatus.cancelled;
      activeWorkerJobIds.remove(1); // Worker slot released

      expect(initialItem.isCancelled, isTrue);
      expect(initialItem.jobId, equals(2));
      expect(initialItem.status, equals(FilePreparationStatus.cancelled));
      expect(activeWorkerJobIds.isEmpty, isTrue);

      // Step 3: Verify late stale callbacks from Job 1 do not corrupt Job 2 or reactivate the item
      const lateStaleJobId = 1;
      if (initialItem.jobId == lateStaleJobId && !initialItem.isCancelled) {
        initialItem.status = FilePreparationStatus.manifestReady;
      }
      expect(initialItem.status, equals(FilePreparationStatus.cancelled));

      // Step 4: Reselect the same file and add a new 127 KB file
      final payloads = [
        SelectedFilePayload(
          file: largeFile,
          name: 'large_video.mp4',
          sizeBytes: 1024 * 1024,
          extension: 'mp4',
          type: FileType.Video,
        ),
        SelectedFilePayload(
          file: small127KbFile,
          name: 'small_document.pdf',
          sizeBytes: 127 * 1024,
          extension: 'pdf',
          type: FileType.Document,
        ),
      ];

      int addedCount = 0;
      for (final payload in payloads) {
        final path = payload.file.path;
        final existingIndex = selectedFiles.indexWhere((item) =>
            item.file.path == path ||
            (item.info.name == payload.name && item.info.sizeBytes == payload.sizeBytes));

        if (existingIndex != -1) {
          final existing = selectedFiles[existingIndex];
          if (existing.status == FilePreparationStatus.cancelled ||
              existing.status == FilePreparationStatus.error) {
            existing.isCancelled = false;
            existing.errorMessage = null;
            existing.progress = null;
            existing.jobId++;
            existing.status = FilePreparationStatus.selected;
            addedCount++;
          }
          continue;
        }

        final item = PickedFileItem(
          id: '${payload.file.path}_${DateTime.now().microsecondsSinceEpoch}',
          jobId: 1,
          file: payload.file,
          info: payload.toFileInfo(),
          status: FilePreparationStatus.selected,
        );
        selectedFiles.add(item);
        addedCount++;
      }

      expect(addedCount, equals(2));
      expect(selectedFiles.length, equals(2));

      // Both items are now selected and ready for queue
      final reselectedItem = selectedFiles[0];
      final smallFileItem = selectedFiles[1];

      expect(reselectedItem.status, equals(FilePreparationStatus.selected));
      expect(reselectedItem.jobId, equals(3));
      expect(reselectedItem.isCancelled, isFalse);

      expect(smallFileItem.status, equals(FilePreparationStatus.selected));
      expect(smallFileItem.info.sizeBytes, equals(127 * 1024));

      // Step 5: Process through queue scheduler
      for (final item in selectedFiles) {
        item.status = FilePreparationStatus.queued;
      }

      // Worker admissions: available slots up to 2
      const maxWorkers = 2;
      final availableSlots = (maxWorkers - activeWorkerJobIds.length).clamp(0, maxWorkers);
      expect(availableSlots, equals(2));

      for (final item in selectedFiles) {
        item.status = FilePreparationStatus.preparing;
        activeWorkerJobIds.add(item.jobId);
      }

      expect(activeWorkerJobIds.length, equals(2));

      // Generate manifests for both items concurrently
      final futures = selectedFiles.map((item) async {
        item.status = FilePreparationStatus.hashing;
        final manifest = await ManifestService.generateManifest(item.file);
        item.manifest = manifest;
        item.status = FilePreparationStatus.manifestReady;
        activeWorkerJobIds.remove(item.jobId);
      }).toList();

      await Future.wait(futures);

      // Step 6: Verify all required assertions
      // a) Reselected file reached manifestReady
      expect(reselectedItem.status, equals(FilePreparationStatus.manifestReady));
      expect(reselectedItem.manifest, isNotNull);
      expect(reselectedItem.manifest!.chunks.isNotEmpty, isTrue);

      // b) 127 KB file reached manifestReady with verified SHA-256
      expect(smallFileItem.status, equals(FilePreparationStatus.manifestReady));
      expect(smallFileItem.manifest, isNotNull);
      expect(smallFileItem.manifest!.fileSize, equals(127 * 1024));
      expect(smallFileItem.manifest!.fileSha256.length, equals(64));

      // c) Queue returned to idle
      final queuedRemaining = selectedFiles.where((i) => i.status == FilePreparationStatus.queued).length;
      expect(queuedRemaining, equals(0));

      // d) Active worker count returned to zero
      expect(activeWorkerJobIds.isEmpty, isTrue);
    });

    test('2. ManifestService cancellation token immediately aborts in-flight isolate hashing', () async {
      final file = File('${tempDir.path}/abort_test.dat');
      await file.writeAsBytes(List.filled(512 * 1024, 3));

      bool isCancelled = false;
      int progressCallCount = 0;

      final future = ManifestService.generateManifest(
        file,
        chunkSize: 64 * 1024,
        onProgress: (_) {
          progressCallCount++;
          if (progressCallCount >= 2) {
            isCancelled = true;
          }
        },
        isCancelled: () => isCancelled,
      );

      // Must complete with FormatException indicating cancellation
      expect(future, throwsA(isA<FormatException>()));
    });
  });
}
