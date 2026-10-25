import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_manifest_progress_test_');
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
  });

  tearDown(() async {
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Single-Pass Manifest Generation & Progress Reporting Tests', () {
    test('1. Manifest generation produces valid whole-file SHA-256 in a single streaming pass', () async {
      final file = File('${tempDir.path}/sample_data.bin');
      // Create a 512 KB synthetic file with repeatable pseudo-random data
      final data = List<int>.generate(512 * 1024, (i) => (i * 31 + 17) & 0xFF);
      await file.writeAsBytes(data, flush: true);

      final expectedHash = await FileHasher.computeFileSha256(file);
      final manifest = await ManifestService.generateManifest(file, chunkSize: 64 * 1024);

      expect(manifest.fileSha256, equals(expectedHash));
      expect(manifest.fileSize, equals(512 * 1024));
      expect(manifest.chunks.length, equals(8));
    });

    test('2. Progress callback emits real-time progress, stages, and chunk counts', () async {
      final file = File('${tempDir.path}/progress_data.bin');
      final data = List<int>.generate(256 * 1024, (i) => (i * 7) & 0xFF);
      await file.writeAsBytes(data, flush: true);

      final progressEvents = <ManifestProgress>[];

      final manifest = await ManifestService.generateManifest(
        file,
        chunkSize: 64 * 1024,
        onProgress: (p) {
          progressEvents.add(p);
        },
      );

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.first.progress, equals(0.0));
      expect(progressEvents.first.bytesProcessed, equals(0));
      expect(progressEvents.first.stage, equals('Calculating SHA-256'));

      expect(progressEvents.last.progress, equals(1.0));
      expect(progressEvents.last.bytesProcessed, equals(256 * 1024));
      expect(progressEvents.last.percentage, equals(100));
      expect(progressEvents.last.currentChunk, equals(4));
      expect(progressEvents.last.totalChunks, equals(4));

      // Verify progress strictly increases
      for (int i = 1; i < progressEvents.length; i++) {
        expect(
          progressEvents[i].bytesProcessed >= progressEvents[i - 1].bytesProcessed,
          isTrue,
        );
        expect(
          progressEvents[i].progress >= progressEvents[i - 1].progress,
          isTrue,
        );
      }

      expect(manifest.chunkCount, equals(4));
    });

    test('3. Manifest generation respects isCancelled callback cleanly', () async {
      final file = File('${tempDir.path}/cancel_data.bin');
      final data = List<int>.generate(1024 * 1024, (i) => i & 0xFF);
      await file.writeAsBytes(data, flush: true);

      int chunkCount = 0;
      bool cancelled = false;

      expect(
        () async => await ManifestService.generateManifest(
          file,
          chunkSize: 64 * 1024,
          onProgress: (p) {
            chunkCount++;
            if (chunkCount >= 3) {
              cancelled = true;
            }
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('4. SelectedFilePayload provides instant metadata without disk blocking', () async {
      final file = File('${tempDir.path}/video_recording.mp4');
      await file.writeAsBytes(List.filled(1024, 0));

      final payload = SelectedFilePayload(
        file: file,
        name: 'video_recording.mp4',
        sizeBytes: 2500000000, // 2.5 GB simulated size
        extension: 'mp4',
        type: FileType.Video,
      );

      final fileInfo = payload.toFileInfo();
      expect(fileInfo.name, equals('video_recording.mp4'));
      expect(fileInfo.sizeBytes, equals(2500000000));
      expect(fileInfo.type, equals(FileType.Video));
      expect(fileInfo.formattedSize, equals('2.33 GB'));
    });

    test('5. FileInfo.fromMetadata produces formatted size and file types synchronously', () {
      final info = FileInfo.fromMetadata(
        path: '/storage/emulated/0/Download/report.pdf',
        name: 'report.pdf',
        sizeBytes: 5242880,
      );

      expect(info.id, equals('/storage/emulated/0/Download/report.pdf'));
      expect(info.name, equals('report.pdf'));
      expect(info.sizeBytes, equals(5242880));
      expect(info.formattedSize, equals('5.0 MB'));
      expect(info.extension, equals('pdf'));
      expect(info.type, equals(FileType.Document));
    });

    test('6. FilePickerService.pickMultipleFilePayloads uses custom handler when provided', () async {
      final dummyFile1 = File('${tempDir.path}/archive.zip');
      final dummyFile2 = File('${tempDir.path}/presentation.pptx');

      FilePickerService.customPayloadPickerHandler = () async => [
        SelectedFilePayload(
          file: dummyFile1,
          name: 'archive.zip',
          sizeBytes: 15000000,
          extension: 'zip',
          type: FileType.Archive,
        ),
        SelectedFilePayload(
          file: dummyFile2,
          name: 'presentation.pptx',
          sizeBytes: 30000000,
          extension: 'pptx',
          type: FileType.Presentation,
        ),
      ];

      final results = await FilePickerService.pickMultipleFilePayloads();
      expect(results.length, equals(2));
      expect(results[0].name, equals('archive.zip'));
      expect(results[0].type, equals(FileType.Archive));
      expect(results[1].name, equals('presentation.pptx'));
      expect(results[1].type, equals(FileType.Presentation));

      // Also verify backward compatibility of pickMultipleFiles()
      final rawFiles = await FilePickerService.pickMultipleFiles();
      expect(rawFiles.length, equals(2));
      expect(rawFiles[0].path, equals(dummyFile1.path));
      expect(rawFiles[1].path, equals(dummyFile2.path));
    });
  });
}
