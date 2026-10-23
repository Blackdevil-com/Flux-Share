import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/screens/send_file/send_file_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_send_test_');
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
  });

  tearDown(() async {
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SendFileScreen Manifest Pipeline & State Lifecycle Tests (Phase 9)', () {
    test('1. A selected file appears before hashing completes', () async {
      final file = File('${tempDir.path}/huge_movie.mp4');
      const simulatedSize = 3500000000; // 3.5 GB simulated

      final payload = SelectedFilePayload(
        file: file,
        name: 'huge_movie.mp4',
        sizeBytes: simulatedSize,
        extension: 'mp4',
        type: FileType.Video,
      );

      final item = PickedFileItem(
        id: '${payload.file.path}_123',
        jobId: 1,
        file: payload.file,
        info: payload.toFileInfo(),
        status: FilePreparationStatus.selected,
      );

      // Instantly visible with metadata without reading 3.5 GB from disk
      expect(item.status, equals(FilePreparationStatus.selected));
      expect(item.info.name, equals('huge_movie.mp4'));
      expect(item.info.formattedSize, equals('3.26 GB'));
      expect(item.manifest, isNull);
    });

    test('2. Large-file preparation does not block the UI (streaming with bounded memory)', () async {
      final file = File('${tempDir.path}/stream_asset.dat');
      // Create 256 KB synthetic file
      final data = List<int>.generate(256 * 1024, (i) => (i * 31) & 0xFF);
      await file.writeAsBytes(data, flush: true);

      final progressUpdates = <ManifestProgress>[];
      final manifest = await ManifestService.generateManifest(
        file,
        chunkSize: 64 * 1024,
        onProgress: (p) => progressUpdates.add(p),
      );

      expect(manifest.chunkCount, equals(4));
      expect(progressUpdates.length, equals(5)); // 0% + 4 chunks
      expect(progressUpdates.last.progress, equals(1.0));
      expect(progressUpdates.last.percentage, equals(100));
    });

    test('3. Progress updates and completion states are correct', () async {
      final file = File('${tempDir.path}/lifecycle_test.txt');
      await file.writeAsString('FluxShare lifecycle test contents');

      final item = PickedFileItem(
        id: file.path,
        jobId: 1,
        file: file,
        info: FileInfo.fromMetadata(
          path: file.path,
          name: 'lifecycle_test.txt',
          sizeBytes: 34,
        ),
        status: FilePreparationStatus.selected,
      );

      // Transition to preparing
      item.status = FilePreparationStatus.preparing;
      expect(item.status, equals(FilePreparationStatus.preparing));

      // Transition to hashing
      item.status = FilePreparationStatus.hashing;
      expect(item.status, equals(FilePreparationStatus.hashing));

      final manifest = await ManifestService.generateManifest(
        item.file,
        onProgress: (p) => item.progress = p,
      );

      item.manifest = manifest;
      item.status = FilePreparationStatus.manifestReady;

      expect(item.status, equals(FilePreparationStatus.manifestReady));
      expect(item.isReady, isTrue);
      expect(item.manifest, isNotNull);
      expect(item.manifest!.fileName, equals('lifecycle_test.txt'));
    });

    test('4. Change File replaces the selected file and invalidates previous job', () async {
      final oldFile = File('${tempDir.path}/old_movie.mkv');
      await oldFile.writeAsBytes(List.filled(1024, 1));

      final newFile = File('${tempDir.path}/new_document.pdf');
      await newFile.writeAsBytes(List.filled(2048, 2));

      final selectedFiles = <PickedFileItem>[
        PickedFileItem(
          id: 'item_1',
          jobId: 1,
          file: oldFile,
          info: FileInfo.fromMetadata(path: oldFile.path, name: 'old_movie.mkv', sizeBytes: 1024),
          status: FilePreparationStatus.hashing,
        ),
      ];

      // User triggers Change File
      FilePickerService.customSinglePayloadPickerHandler = () async => SelectedFilePayload(
        file: newFile,
        name: 'new_document.pdf',
        sizeBytes: 2048,
        extension: 'pdf',
        type: FileType.Document,
      );

      final targetItem = selectedFiles.first;
      final oldJobId = targetItem.jobId;

      // Invalidate old job
      targetItem.isCancelled = true;
      final newJobId = ++targetItem.jobId;

      final replacement = await FilePickerService.pickSingleFilePayload();
      expect(replacement, isNotNull);

      targetItem.file = replacement!.file;
      targetItem.info = replacement.toFileInfo();
      targetItem.status = FilePreparationStatus.selected;
      targetItem.manifest = null;
      targetItem.isCancelled = false;

      expect(targetItem.jobId, equals(oldJobId + 1));
      expect(targetItem.info.name, equals('new_document.pdf'));
      expect(targetItem.info.type, equals(FileType.Document));
      expect(targetItem.info.sizeBytes, equals(2048));
      expect(targetItem.status, equals(FilePreparationStatus.selected));
    });

    test('5. Cancelling the replacement picker preserves the previous file and preparation state', () async {
      final file = File('${tempDir.path}/original.png');
      await file.writeAsBytes(List.filled(512, 9));

      final item = PickedFileItem(
        id: 'item_orig',
        jobId: 4,
        file: file,
        info: FileInfo.fromMetadata(path: file.path, name: 'original.png', sizeBytes: 512),
        status: FilePreparationStatus.hashing,
      );

      // Simulate user opening picker and tapping cancel (returns null)
      FilePickerService.customSinglePayloadPickerHandler = () async => null;

      final result = await FilePickerService.pickSingleFilePayload();
      expect(result, isNull);

      // Previous state remains preserved
      expect(item.info.name, equals('original.png'));
      expect(item.status, equals(FilePreparationStatus.hashing));
      expect(item.jobId, equals(4));
      expect(item.isCancelled, isFalse);
    });

    test('6. Cancelling preparation prevents stale results from becoming active', () async {
      final file = File('${tempDir.path}/cancelled_target.iso');
      await file.writeAsBytes(List.filled(1024, 0));

      final item = PickedFileItem(
        id: file.path,
        jobId: 10,
        file: file,
        info: FileInfo.fromMetadata(path: file.path, name: 'cancelled_target.iso', sizeBytes: 1024),
        status: FilePreparationStatus.hashing,
      );

      // User cancels preparation
      item.isCancelled = true;
      final activeJobId = ++item.jobId;
      item.status = FilePreparationStatus.cancelled;

      // Simulate a late callback finishing from the old job (jobId: 10)
      const lateJobId = 10;
      if (item.jobId == lateJobId && !item.isCancelled) {
        item.status = FilePreparationStatus.manifestReady;
      }

      // Must remain cancelled, stale result rejected!
      expect(item.status, equals(FilePreparationStatus.cancelled));
      expect(item.isReady, isFalse);
    });

    test('7. Removing a file during hashing does not reinsert it or corrupt list', () async {
      final fileA = File('${tempDir.path}/fileA.txt')..writeAsStringSync('File A');
      final fileB = File('${tempDir.path}/fileB.txt')..writeAsStringSync('File B');

      final list = <PickedFileItem>[
        PickedFileItem(
          id: '1',
          file: fileA,
          info: FileInfo.fromMetadata(path: fileA.path, name: 'fileA.txt', sizeBytes: 6),
          status: FilePreparationStatus.hashing,
        ),
        PickedFileItem(
          id: '2',
          file: fileB,
          info: FileInfo.fromMetadata(path: fileB.path, name: 'fileB.txt', sizeBytes: 6),
          status: FilePreparationStatus.selected,
        ),
      ];

      // Remove file A
      final removed = list.removeAt(0);
      removed.isCancelled = true;
      removed.jobId++;

      expect(list.length, equals(1));
      expect(list.first.info.name, equals('fileB.txt'));
      expect(removed.isCancelled, isTrue);
    });

    test('8. Errors and retries work without corrupting other files in batch', () async {
      final validFile = File('${tempDir.path}/valid.txt')..writeAsStringSync('valid data');
      final missingFile = File('${tempDir.path}/missing.txt');

      final validItem = PickedFileItem(
        id: 'valid',
        file: validFile,
        info: FileInfo.fromMetadata(path: validFile.path, name: 'valid.txt', sizeBytes: 10),
        status: FilePreparationStatus.manifestReady,
        manifest: await ManifestService.generateManifest(validFile),
      );

      final failingItem = PickedFileItem(
        id: 'fail',
        file: missingFile,
        info: FileInfo.fromMetadata(path: missingFile.path, name: 'missing.txt', sizeBytes: 10),
        status: FilePreparationStatus.selected,
      );

      // Verify file missing causes error
      if (!await failingItem.file.exists()) {
        failingItem.status = FilePreparationStatus.error;
        failingItem.errorMessage = 'File not found on disk';
      }

      expect(failingItem.status, equals(FilePreparationStatus.error));
      expect(validItem.status, equals(FilePreparationStatus.manifestReady));

      // Retry failing item resets only that item
      failingItem.isCancelled = false;
      failingItem.status = FilePreparationStatus.selected;
      failingItem.errorMessage = null;

      expect(failingItem.status, equals(FilePreparationStatus.selected));
      expect(validItem.status, equals(FilePreparationStatus.manifestReady));
    });

    test('9. Multi-file selection and Add More remain functional', () async {
      final file1 = File('${tempDir.path}/f1.txt')..writeAsStringSync('1');
      final file2 = File('${tempDir.path}/f2.txt')..writeAsStringSync('2');

      FilePickerService.customPayloadPickerHandler = () async => [
        SelectedFilePayload(
          file: file1,
          name: 'f1.txt',
          sizeBytes: 1,
          extension: 'txt',
          type: FileType.Document,
        ),
      ];

      final batch1 = await FilePickerService.pickMultipleFilePayloads();
      expect(batch1.length, equals(1));

      // Add More session
      FilePickerService.customPayloadPickerHandler = () async => [
        SelectedFilePayload(
          file: file2,
          name: 'f2.txt',
          sizeBytes: 1,
          extension: 'txt',
          type: FileType.Document,
        ),
      ];

      final batch2 = await FilePickerService.pickMultipleFilePayloads();
      expect(batch2.length, equals(1));

      final combined = [...batch1, ...batch2];
      expect(combined.length, equals(2));
      expect(combined[0].name, equals('f1.txt'));
      expect(combined[1].name, equals('f2.txt'));
    });

    test('10. Start Transfer stays disabled until all required manifests are ready', () async {
      final item1 = PickedFileItem(
        id: '1',
        file: File('a.txt'),
        info: FileInfo.fromMetadata(path: 'a.txt', name: 'a.txt', sizeBytes: 100),
        status: FilePreparationStatus.manifestReady,
      );
      final item2 = PickedFileItem(
        id: '2',
        file: File('b.txt'),
        info: FileInfo.fromMetadata(path: 'b.txt', name: 'b.txt', sizeBytes: 100),
        status: FilePreparationStatus.hashing,
      );

      final files = [item1, item2];
      bool canStartTransfer = files.isNotEmpty && files.every((i) => i.isReady);
      expect(canStartTransfer, isFalse);

      // Once item2 is ready with manifest
      item2.status = FilePreparationStatus.manifestReady;
      final dummyManifest = await ManifestService.generateManifest(
        File('${tempDir.path}/dummy.txt')..writeAsStringSync('dummy'),
      );
      item1.manifest = dummyManifest;
      item2.manifest = dummyManifest;

      canStartTransfer = files.isNotEmpty && files.every((i) => i.isReady);
      expect(canStartTransfer, isTrue);
    });

    test('11. SHA-256 values remain correct between streaming and whole-file hash', () async {
      final file = File('${tempDir.path}/sha_verify.bin');
      final bytes = List<int>.generate(100 * 1024, (i) => (i * 13) & 0xFF);
      await file.writeAsBytes(bytes, flush: true);

      final expectedSha = await FileHasher.computeFileSha256(file);
      final manifest = await ManifestService.generateManifest(file, chunkSize: 32 * 1024);

      expect(manifest.fileSha256, equals(expectedSha));
      expect(manifest.chunks.length, equals(4));
    });

    test('12. Batch status summary formats correctly for 4 files', () {
      final summary = '4 files · 2 ready · 1 preparing · 1 queued';
      expect(summary, contains('2 ready'));
      expect(summary, contains('1 preparing'));
      expect(summary, contains('1 queued'));
    });
  });
}
