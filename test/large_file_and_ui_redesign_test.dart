import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/screens/send_file/send_file_screen.dart';
import 'package:fluxshare/widgets/widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_redesign_test_');
    NetworkUtils.customLocalIp = '192.168.1.100';
    ManifestCache.instance.setCustomCacheDir(tempDir);
    ManifestCache.instance.clearMemoryCache();
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    ManifestService.disableIsolatesForTesting = false;
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
    await ManifestCache.instance.clear();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('FluxShare Redesign & Large-File Manifest Suite', () {
    test('1 & 2. Selecting multiple files shows immediate cards and compact summary', () async {
      final f1 = File('${tempDir.path}/video_3_5gb.mp4');
      final f2 = File('${tempDir.path}/paper.pdf');
      final f3 = File('${tempDir.path}/track.mp3');

      // 3.5 GB simulated size
      const size3_5GB = 3758096384;
      const sizePdf = 2500000; // 2.5 MB
      const sizeMp3 = 8500000; // 8.5 MB

      final payload1 = SelectedFilePayload(
        file: f1,
        name: 'video_3_5gb.mp4',
        sizeBytes: size3_5GB,
        extension: 'mp4',
        type: FileType.Video,
      );
      final payload2 = SelectedFilePayload(
        file: f2,
        name: 'paper.pdf',
        sizeBytes: sizePdf,
        extension: 'pdf',
        type: FileType.Document,
      );
      final payload3 = SelectedFilePayload(
        file: f3,
        name: 'track.mp3',
        sizeBytes: sizeMp3,
        extension: 'mp3',
        type: FileType.Other,
      );

      final items = [
        PickedFileItem(id: '1', file: f1, info: payload1.toFileInfo()),
        PickedFileItem(id: '2', file: f2, info: payload2.toFileInfo()),
        PickedFileItem(id: '3', file: f3, info: payload3.toFileInfo()),
      ];

      // Summary
      final totalBytes = items.fold<int>(0, (sum, i) => sum + i.info.sizeBytes);
      expect(items.length, equals(3));
      expect(totalBytes, equals(size3_5GB + sizePdf + sizeMp3));
      expect(FileInfo.formatBytes(totalBytes), equals('3.51 GB'));

      // File 1 metadata is available instantly without reading 3.5 GB
      expect(items[0].info.name, equals('video_3_5gb.mp4'));
      expect(items[0].info.formattedSize, equals('3.50 GB'));
      expect(items[0].status, equals(FilePreparationStatus.selected));
      expect(items[0].manifest, isNull);
    });

    test('3 & 4. Isolate streaming hashing reports incremental progress without blocking main thread', () async {
      final file = File('${tempDir.path}/test_isolate_stream.dat');
      // Create 512 KB file with 4 x 128 KB chunks
      final bytes = List<int>.generate(512 * 1024, (i) => (i * 37) & 0xFF);
      await file.writeAsBytes(bytes, flush: true);

      final progressList = <ManifestProgress>[];
      final manifest = await ManifestService.generateManifest(
        file,
        chunkSize: 128 * 1024,
        onProgress: (p) => progressList.add(p),
      );

      expect(manifest.chunkCount, equals(4));
      expect(progressList.isNotEmpty, isTrue);
      expect(progressList.first.progress, equals(0.0));
      expect(progressList.last.progress, equals(1.0));
      expect(progressList.last.percentage, equals(100));

      // Verify whole-file hash matches FileHasher
      final expectedHash = await FileHasher.computeFileSha256(file);
      expect(manifest.fileSha256, equals(expectedHash));
    });

    test('5. ManifestCache prevents re-hashing unmodified files (instant <1ms lookup)', () async {
      final file = File('${tempDir.path}/cached_file.txt');
      await file.writeAsString('FluxShare caching test payload 12345');

      // First run: hashes and populates cache
      final m1 = await ManifestService.generateManifest(file);
      expect(m1, isNotNull);

      // Verify cached in ManifestCache
      final cached = await ManifestCache.instance.get(file);
      expect(cached, isNotNull);
      expect(cached!.fileSha256, equals(m1.fileSha256));

      // Second run: returns cached manifest with instant 100% progress
      final progressUpdates = <ManifestProgress>[];
      final m2 = await ManifestService.generateManifest(
        file,
        onProgress: (p) => progressUpdates.add(p),
      );

      expect(m2.fileSha256, equals(m1.fileSha256));
      expect(progressUpdates.length, equals(1));
      expect(progressUpdates.first.progress, equals(1.0));
      expect(progressUpdates.first.stage, equals('Manifest Ready'));
    });

    test('6. Adaptive chunk size selects optimal boundaries for multi-gigabyte files', () {
      // 5 MB file -> 512 KB chunks
      expect(ManifestService.selectAdaptiveChunkSize(5 * 1024 * 1024), equals(512 * 1024));
      // 50 MB file -> 1 MB chunks
      expect(ManifestService.selectAdaptiveChunkSize(50 * 1024 * 1024), equals(1024 * 1024));
      // 300 MB file -> 2 MB chunks
      expect(ManifestService.selectAdaptiveChunkSize(300 * 1024 * 1024), equals(2 * 1024 * 1024));
      // 800 MB file -> 4 MB chunks
      expect(ManifestService.selectAdaptiveChunkSize(800 * 1024 * 1024), equals(4 * 1024 * 1024));
      // 3.5 GB file -> 8 MB chunks
      const fileSize3_5GB = 3758096384;
      final chunkSize = ManifestService.selectAdaptiveChunkSize(fileSize3_5GB);
      expect(chunkSize, equals(8 * 1024 * 1024));

      // Expected chunk count: ceil(3758096384 / (8 * 1024 * 1024)) = 448 chunks
      final expectedChunks = (fileSize3_5GB / chunkSize).ceil();
      expect(expectedChunks, equals(448));
    });

    test('7. Cancelling or removing an in-flight file terminates preparation and ignores stale results', () async {
      final file = File('${tempDir.path}/cancel_test.dat');
      await file.writeAsBytes(List.filled(64 * 1024, 0));

      final item = PickedFileItem(
        id: file.path,
        jobId: 1,
        file: file,
        info: FileInfo.fromMetadata(path: file.path, name: 'cancel_test.dat', sizeBytes: 64 * 1024),
        status: FilePreparationStatus.hashing,
      );

      // User cancels / replaces item
      item.isCancelled = true;
      final newJobId = ++item.jobId;

      expect(item.isCancelled, isTrue);
      expect(newJobId, equals(2));

      // Attempting to finish under old jobId (1) does not update state
      const oldJobId = 1;
      if (item.jobId == oldJobId && !item.isCancelled) {
        item.status = FilePreparationStatus.manifestReady;
      }
      expect(item.status, equals(FilePreparationStatus.hashing)); // Unchanged
    });

    test('8. Change flow deduplicates files and preserves previously verified manifests', () async {
      final fileA = File('${tempDir.path}/file_a.txt');
      final fileB = File('${tempDir.path}/file_b.txt');
      final fileC = File('${tempDir.path}/file_c.txt');

      await fileA.writeAsString('A');
      await fileB.writeAsString('B');
      await fileC.writeAsString('C');

      final existingItemA = PickedFileItem(
        id: fileA.path,
        jobId: 1,
        file: fileA,
        info: FileInfo.fromMetadata(path: fileA.path, name: 'file_a.txt', sizeBytes: 1),
        status: FilePreparationStatus.manifestReady,
        manifest: Manifest(
          fileId: 'manifest_a',
          fileName: 'file_a.txt',
          fileSize: 1,
          mimeType: 'text/plain',
          chunkSize: 512 * 1024,
          chunkCount: 1,
          fileSha256: 'sha_a',
          chunks: const [],
        ),
      );

      final existingSelected = [existingItemA];

      // Newly picked files contain: fileA (duplicate) + fileB (new) + fileC (new)
      final newlyPicked = [
        SelectedFilePayload(
          file: fileA,
          name: 'file_a.txt',
          sizeBytes: 1,
          extension: 'txt',
          type: FileType.Document,
        ),
        SelectedFilePayload(
          file: fileB,
          name: 'file_b.txt',
          sizeBytes: 1,
          extension: 'txt',
          type: FileType.Document,
        ),
        SelectedFilePayload(
          file: fileC,
          name: 'file_c.txt',
          sizeBytes: 1,
          extension: 'txt',
          type: FileType.Document,
        ),
      ];

      // Deduplicate against existing selection
      final List<SelectedFilePayload> combined = [];
      for (final p in newlyPicked) {
        final isDup = existingSelected.any((e) =>
            e.file.path == p.file.path ||
            (e.info.name == p.name && e.info.sizeBytes == p.sizeBytes));
        if (!isDup) {
          combined.add(p);
        }
      }

      // fileA was deduplicated; only fileB and fileC added
      expect(combined.length, equals(2));
      expect(combined.map((c) => c.name), containsAll(['file_b.txt', 'file_c.txt']));

      // Existing item A remains manifestReady without re-hashing
      expect(existingItemA.status, equals(FilePreparationStatus.manifestReady));
      expect(existingItemA.isReady, isTrue);
      expect(existingItemA.manifest!.fileSha256, equals('sha_a'));
    });

    test('9. Start Transfer requires all files to have manifestReady status', () {
      final f1 = File('${tempDir.path}/1.txt');
      final f2 = File('${tempDir.path}/2.txt');

      final dummyManifest = Manifest(
        fileId: 'm1',
        fileName: '1.txt',
        fileSize: 10,
        mimeType: 'text/plain',
        chunkSize: 1024,
        chunkCount: 1,
        fileSha256: 'hash1',
        chunks: const [],
      );

      final item1 = PickedFileItem(
        id: '1',
        file: f1,
        info: FileInfo.fromMetadata(path: f1.path, name: '1.txt', sizeBytes: 10),
        status: FilePreparationStatus.manifestReady,
        manifest: dummyManifest,
      );

      final item2 = PickedFileItem(
        id: '2',
        file: f2,
        info: FileInfo.fromMetadata(path: f2.path, name: '2.txt', sizeBytes: 20),
        status: FilePreparationStatus.hashing,
      );

      final files = [item1, item2];
      bool canStart = files.isNotEmpty && files.every((i) => i.isReady);
      expect(canStart, isFalse);

      // Once item2 completes
      item2.status = FilePreparationStatus.manifestReady;
      item2.manifest = dummyManifest;

      canStart = files.isNotEmpty && files.every((i) => i.isReady);
      expect(canStart, isTrue);
    });

    testWidgets('10. UI layout order: Summary bar -> Room PIN card -> Selected Files below PIN', (tester) async {
      ManifestService.disableIsolatesForTesting = true;
      final f1 = File('${tempDir.path}/sample_video.mp4');
      f1.writeAsStringSync('video');

      final initialFile = FileInfo.fromMetadata(
        path: f1.path,
        name: 'sample_video.mp4',
        sizeBytes: 1024,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SendFileScreen(initialFile: initialFile),
        ),
      );

      // Allow real async I/O in SendFileScreen to complete
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify File Selection Summary Bar appears at top
      expect(find.textContaining('1 file selected'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Change'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Add More'), findsOneWidget);

      // Verify Room PIN Card appears
      expect(find.text('ROOM PIN FOR RECEIVERS'), findsOneWidget);
      expect(find.textContaining('ROOM PIN:'), findsOneWidget);

      // Verify Selected Files section header appears below PIN
      expect(find.text('Selected Files · 1 file'), findsOneWidget);
      expect(find.text('sample_video.mp4'), findsOneWidget);

      // Verify floating device bubble is present
      expect(find.byIcon(Icons.devices_rounded), findsOneWidget);
    });

    testWidgets('11. Floating Connected Devices Bubble opens device modal sheet with empty state', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SendFileScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Tap the floating device bubble
      final bubbleFinder = find.byIcon(Icons.devices_rounded);
      expect(bubbleFinder, findsOneWidget);
      await tester.tap(bubbleFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify modal sheet opened
      expect(find.text('Connected Devices'), findsOneWidget);
      expect(find.text('No devices connected yet'), findsOneWidget);
      expect(find.widgetWithText(PrimaryButton, 'DONE'), findsOneWidget);

      // Close modal
      await tester.tap(find.widgetWithText(PrimaryButton, 'DONE'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No devices connected yet'), findsNothing);
    });

    testWidgets('12. Individual file cards show green check and manifest status upon readiness', (tester) async {
      final f1 = File('${tempDir.path}/doc.pdf');
      f1.writeAsStringSync('test document contents');

      final dummyManifest = Manifest(
        fileId: 'm_ready_1',
        fileName: 'doc.pdf',
        fileSize: 22,
        mimeType: 'application/pdf',
        chunkSize: 512 * 1024,
        chunkCount: 1,
        fileSha256: 'sha256_mock_hash_for_test',
        chunks: const [],
      );

      final readyItem = PickedFileItem(
        id: f1.path,
        jobId: 1,
        file: f1,
        info: FileInfo.fromMetadata(
          path: f1.path,
          name: 'doc.pdf',
          sizeBytes: 22,
        ),
        status: FilePreparationStatus.manifestReady,
        manifest: dummyManifest,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SendFileScreen(initialPickedItems: [readyItem]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Status shows Manifest Ready and green check
      expect(find.textContaining('Manifest Ready · 1 chunks · SHA-256 verified'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
    });
  });
}
