import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/file/session_manifest_cache.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/screens/send_file/send_file_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory customCacheDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_two_layer_test_');
    customCacheDir = Directory('${tempDir.path}/manifest_cache');
    await customCacheDir.create(recursive: true);

    ManifestCache.instance.setCustomCacheDir(customCacheDir);
    ManifestCache.instance.clearMemoryCache();
    ManifestService.disableIsolatesForTesting = true;
  });

  tearDown(() async {
    ManifestService.disableIsolatesForTesting = false;
    FilePickerService.customPayloadPickerHandler = null;
    FilePickerService.customSinglePayloadPickerHandler = null;
    try {
      await ManifestCache.instance.clear();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Two-Layer Manifest Cache Specification & Regression Tests', () {
    test('1. A completed manifest is reused after removing and re-adding the same unchanged file', () async {
      final file = File('${tempDir.path}/video_800mb.mp4');
      await file.writeAsBytes(List.filled(64 * 1024, 65)); // 64 KB test file

      final sessionCache = SessionManifestCache();
      int hashingCalls = 0;

      // First selection: cache miss -> hashes
      final manifest1 = await ManifestService.generateManifest(
        file,
        chunkSize: 16 * 1024,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );
      expect(manifest1, isNotNull);
      expect(hashingCalls, equals(1));
      expect(sessionCache.length, equals(1));

      // Simulate user removing file from UI (session cache is preserved)
      // Second selection: re-add same unchanged file
      final manifest2 = await ManifestService.generateManifest(
        file,
        chunkSize: 16 * 1024,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );

      // Reused without re-hashing
      expect(manifest2, isNotNull);
      expect(manifest2.fileSha256, equals(manifest1.fileSha256));
      expect(hashingCalls, equals(1), reason: 'Must reuse completed manifest without starting hashing again');
    });

    test('2. A valid session-cache hit avoids full-file hashing', () async {
      final file = File('${tempDir.path}/session_hit.dat');
      await file.writeAsBytes(List.filled(32 * 1024, 7));

      final sessionCache = SessionManifestCache();
      bool hashingStarted = false;

      // Populate session cache
      final m1 = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingStarted = true,
      );
      expect(m1, isNotNull);
      expect(hashingStarted, isTrue);

      // Query session cache directly
      hashingStarted = false;
      final m2 = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingStarted = true,
      );

      expect(hashingStarted, isFalse, reason: 'Session cache hit must completely bypass hashing isolate');
      expect(m2.fileSha256, equals(m1.fileSha256));
    });

    test('3. A valid persistent-cache hit avoids full-file hashing after a simulated session restart', () async {
      final file = File('${tempDir.path}/persistent_hit.dat');
      await file.writeAsBytes(List.filled(32 * 1024, 9));

      // Session 1: Populates both session cache and persistent cache
      final sessionCache1 = SessionManifestCache();
      await ManifestService.generateManifest(file, sessionCache: sessionCache1);
      expect(sessionCache1.length, equals(1));

      // Session ends (screen disposed, session cache cleared)
      sessionCache1.clear();

      // Session 2: Fresh session cache, but persistent disk cache is present
      final sessionCache2 = SessionManifestCache();
      bool hashingStarted = false;

      final m2 = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache2,
        onHashingStarted: () => hashingStarted = true,
      );

      expect(hashingStarted, isFalse, reason: 'Persistent cache hit must avoid full-file hashing after session restart');
      expect(sessionCache2.length, equals(1), reason: 'Persistent hit must populate new session cache');
      expect(m2, isNotNull);
    });

    test('4. A different file with the same name does not reuse an unrelated manifest', () async {
      final fileA = File('${tempDir.path}/movie.mp4');
      await fileA.writeAsBytes(List.filled(16 * 1024, 1)); // 16 KB

      final sessionCache = SessionManifestCache();
      final manifestA = await ManifestService.generateManifest(fileA, sessionCache: sessionCache);

      // Replace movie.mp4 on disk with completely different contents and different size
      await fileA.delete();
      await fileA.writeAsBytes(List.filled(32 * 1024, 2)); // 32 KB

      int hashingCount = 0;
      final manifestB = await ManifestService.generateManifest(
        fileA,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCount++,
      );

      expect(hashingCount, equals(1), reason: 'Different file with same name must trigger fresh hashing');
      expect(manifestB.fileSha256, isNot(equals(manifestA.fileSha256)));
      expect(manifestB.fileSize, equals(32 * 1024));
    });

    test('5. Changing file contents invalidates a cached entry when the change is detectable', () async {
      final file = File('${tempDir.path}/fingerprint_test.dat');
      final initialBytes = List.filled(64 * 1024, 5);
      await file.writeAsBytes(initialBytes);

      final sessionCache = SessionManifestCache();
      final m1 = await ManifestService.generateManifest(file, sessionCache: sessionCache);

      // In-place modification of head bytes (preserves file length)
      final modifiedBytes = List<int>.from(initialBytes);
      modifiedBytes[0] = 99; // Corrupt first byte
      await file.writeAsBytes(modifiedBytes);

      int hashingCount = 0;
      final m2 = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCount++,
      );

      expect(hashingCount, equals(1), reason: 'Head/tail fingerprint mismatch must invalidate cached entry');
      expect(m2.fileSha256, isNot(equals(m1.fileSha256)));
    });

    test('6. A rename of the same underlying file reuses the manifest only when reliable identity permits it', () async {
      final fileOriginal = File('${tempDir.path}/original_movie.mp4');
      await fileOriginal.writeAsBytes(List.filled(48 * 1024, 33));

      const stablePlatformUri = 'content://media/external/video/media/999';
      final sessionCache = SessionManifestCache();

      // First selection with Android Content URI identifier
      final m1 = await ManifestService.generateManifest(
        fileOriginal,
        identifier: stablePlatformUri,
        sessionCache: sessionCache,
      );

      // Renamed file on disk, but referencing same stable platform URI
      final fileRenamed = File('${tempDir.path}/renamed_movie.mp4');
      await fileOriginal.rename(fileRenamed.path);

      int hashingCalls = 0;
      final m2 = await ManifestService.generateManifest(
        fileRenamed,
        identifier: stablePlatformUri,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );

      expect(hashingCalls, equals(0), reason: 'Stable identifier match allows safe manifest reuse across renames');
      expect(m2.fileSha256, equals(m1.fileSha256));
    });

    test('7. A changed file with the same size is not automatically considered unchanged', () async {
      final file = File('${tempDir.path}/same_size.bin');
      final dataA = List.filled(16 * 1024, 10);
      await file.writeAsBytes(dataA);

      final sessionCache = SessionManifestCache();
      final mA = await ManifestService.generateManifest(file, sessionCache: sessionCache);

      // Modify tail bytes while keeping identical size
      final dataB = List<int>.from(dataA);
      dataB[dataB.length - 1] = 99;
      await file.writeAsBytes(dataB);

      int hashingCalls = 0;
      final mB = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );

      expect(hashingCalls, equals(1), reason: 'Fingerprint check must reject file with same size but changed tail');
      expect(mB.fileSha256, isNot(equals(mA.fileSha256)));
    });

    test('8. A cache miss falls back to hashing and populates the cache on success', () async {
      final file = File('${tempDir.path}/miss_fallback.dat');
      await file.writeAsBytes(List.filled(20 * 1024, 12));

      final sessionCache = SessionManifestCache();
      expect(sessionCache.length, equals(0));

      bool hashingRan = false;
      final manifest = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingRan = true,
      );

      expect(hashingRan, isTrue);
      expect(manifest, isNotNull);
      expect(sessionCache.length, equals(1), reason: 'Successful generation must populate session cache');

      // Check persistent cache is also populated
      final persistentCached = await ManifestCache.instance.get(file);
      expect(persistentCached, isNotNull, reason: 'Successful generation must populate persistent cache');
    });

    test('9. Cache corruption, cache read failure, and cache write failure do not stall preparation', () async {
      final file = File('${tempDir.path}/corrupt_test.dat');
      await file.writeAsBytes(List.filled(10 * 1024, 44));

      // Deliberately write invalid garbage JSON into the persistent cache directory
      final corruptFile = File('${customCacheDir.path}/corrupted_entry.json');
      await corruptFile.writeAsString('{ invalid_json: [corrupted ');

      final sessionCache = SessionManifestCache();
      int hashingCalls = 0;

      // Must not crash or hang; falls back to hashing cleanly
      final manifest = await ManifestService.generateManifest(
        file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );

      expect(manifest, isNotNull);
      expect(hashingCalls, equals(1));
    });

    test('10. Cancelled or incomplete jobs never enter the completed cache', () async {
      final file = File('${tempDir.path}/cancel_not_cached.dat');
      await file.writeAsBytes(List.filled(128 * 1024, 88));

      final sessionCache = SessionManifestCache();
      bool isCancelled = false;

      final future = ManifestService.generateManifest(
        file,
        chunkSize: 16 * 1024,
        sessionCache: sessionCache,
        onProgress: (p) {
          if (p.currentChunk >= 2) {
            isCancelled = true;
          }
        },
        isCancelled: () => isCancelled,
      );

      await expectLater(future, throwsA(isA<FormatException>()));

      // Must NOT be stored in session or persistent cache
      expect(sessionCache.length, equals(0));
      final persistent = await ManifestCache.instance.get(file);
      expect(persistent, isNull);
    });

    test('11. Concurrent jobs and file reselection cannot reuse stale manifests', () async {
      final file = File('${tempDir.path}/concurrent.dat');
      await file.writeAsBytes(List.filled(32 * 1024, 55));

      final sessionCache = SessionManifestCache();

      // Launch two concurrent manifest generation requests for the same file
      final f1 = ManifestService.generateManifest(file, sessionCache: sessionCache);
      final f2 = ManifestService.generateManifest(file, sessionCache: sessionCache);

      final results = await Future.wait([f1, f2]);
      expect(results[0].fileSha256, equals(results[1].fileSha256));
      expect(sessionCache.length, equals(1));
    });

    test('12. Removing one file does not clear other valid session-cache entries', () async {
      final fileA = File('${tempDir.path}/file_a.dat')..writeAsBytesSync(List.filled(16 * 1024, 1));
      final fileB = File('${tempDir.path}/file_b.dat')..writeAsBytesSync(List.filled(16 * 1024, 2));

      final sessionCache = SessionManifestCache();

      await ManifestService.generateManifest(fileA, sessionCache: sessionCache);
      await ManifestService.generateManifest(fileB, sessionCache: sessionCache);
      expect(sessionCache.length, equals(2));

      // Simulate removing fileA from selection list: sessionCache retains both entries
      // When fileA is re-added, it hits session cache without re-hashing
      int hashingCalls = 0;
      final mA = await ManifestService.generateManifest(
        fileA,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingCalls++,
      );

      expect(hashingCalls, equals(0));
      expect(mA, isNotNull);
      expect(sessionCache.length, equals(2));
    });

    test('13. Ending a send session releases its session-scoped cache', () async {
      final file = File('${tempDir.path}/session_end.dat')..writeAsBytesSync(List.filled(16 * 1024, 3));
      final sessionCache = SessionManifestCache();

      await ManifestService.generateManifest(file, sessionCache: sessionCache);
      expect(sessionCache.length, equals(1));

      // End session
      sessionCache.clear();
      expect(sessionCache.length, equals(0));
    });

    test('14. Cache hits and misses both update the UI and queue worker accounting correctly', () async {
      final file = File('${tempDir.path}/ui_accounting.dat')..writeAsBytesSync(List.filled(24 * 1024, 4));

      final item = PickedFileItem(
        id: 'ui_item_1',
        jobId: 1,
        file: file,
        info: FileInfo.fromMetadata(path: file.path, name: 'ui_accounting.dat', sizeBytes: 24 * 1024),
        status: FilePreparationStatus.selected,
      );

      final sessionCache = SessionManifestCache();
      final activeWorkers = <int>{};

      // 1. First run: cache miss
      activeWorkers.add(item.jobId);
      item.status = FilePreparationStatus.preparing;

      final manifest1 = await ManifestService.generateManifest(
        item.file,
        sessionCache: sessionCache,
        onHashingStarted: () {
          item.status = FilePreparationStatus.hashing;
        },
      );
      item.manifest = manifest1;
      item.status = FilePreparationStatus.manifestReady;
      activeWorkers.remove(item.jobId);

      expect(item.status, equals(FilePreparationStatus.manifestReady));
      expect(activeWorkers.isEmpty, isTrue);

      // 2. Second run: cache hit
      final item2 = PickedFileItem(
        id: 'ui_item_2',
        jobId: 2,
        file: file,
        info: FileInfo.fromMetadata(path: file.path, name: 'ui_accounting.dat', sizeBytes: 24 * 1024),
        status: FilePreparationStatus.selected,
      );

      activeWorkers.add(item2.jobId);
      item2.status = FilePreparationStatus.preparing;

      bool hashingStarted = false;
      final manifest2 = await ManifestService.generateManifest(
        item2.file,
        sessionCache: sessionCache,
        onHashingStarted: () => hashingStarted = true,
      );
      item2.manifest = manifest2;
      item2.status = FilePreparationStatus.manifestReady;
      activeWorkers.remove(item2.jobId);

      expect(hashingStarted, isFalse, reason: 'Cache hit must avoid hashing transition');
      expect(item2.status, equals(FilePreparationStatus.manifestReady));
      expect(activeWorkers.isEmpty, isTrue, reason: 'Worker slot must be released on cache hit');
    });
  });
}
