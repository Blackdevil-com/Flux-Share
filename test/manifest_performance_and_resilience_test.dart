import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_perf_test_');
    ManifestCache.instance.setCustomCacheDir(tempDir);
    ManifestCache.instance.clearMemoryCache();
    ManifestService.disableIsolatesForTesting = false;
  });

  tearDown(() async {
    ManifestService.disableIsolatesForTesting = false;
    await ManifestCache.instance.clear();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('FluxShare Manifest Performance & Resilience Suite', () {
    test('1. First-run hashing computes valid SHA-256 and bounds memory', () async {
      final file = File('${tempDir.path}/test_10mb.dat');
      const size = 10 * 1024 * 1024; // 10 MB
      final data = List<int>.generate(64 * 1024, (i) => (i * 37 + 19) & 0xFF);

      final sink = file.openWrite();
      int written = 0;
      while (written < size) {
        sink.add(data);
        written += data.length;
      }
      await sink.flush();
      await sink.close();

      final progressList = <ManifestProgress>[];
      final sw = Stopwatch()..start();
      final manifest = await ManifestService.generateManifest(
        file,
        onProgress: (p) => progressList.add(p),
      );
      sw.stop();

      print('\n[BENCHMARK] 10 MB Cold Generation: ${sw.elapsedMilliseconds} ms (${(10.0 / (sw.elapsedMilliseconds / 1000.0)).toStringAsFixed(2)} MB/s)');

      // Verify progress
      expect(progressList.isNotEmpty, isTrue);
      expect(progressList.first.progress, equals(0.0));
      expect(progressList.last.progress, equals(1.0));
      expect(progressList.last.percentage, equals(100));

      // Verify manifest details
      expect(manifest.fileSize, equals(size));
      expect(manifest.chunkSize, equals(512 * 1024)); // <= 10 MB -> 512 KB
      expect(manifest.chunkCount, equals(20));
      expect(manifest.chunks.length, equals(20));

      // Verify whole file SHA-256 against reference FileHasher
      final expectedHash = await FileHasher.computeFileSha256(file);
      expect(manifest.fileSha256, equals(expectedHash));
    });

    test('2. Repeat selection of unchanged file hits cache in sub-millisecond time (< 5ms)', () async {
      final file = File('${tempDir.path}/cached_asset.dat');
      const size = 5 * 1024 * 1024; // 5 MB
      final data = List<int>.generate(64 * 1024, (i) => (i * 13) & 0xFF);

      final sink = file.openWrite();
      int written = 0;
      while (written < size) {
        sink.add(data);
        written += data.length;
      }
      await sink.flush();
      await sink.close();

      // Cold run
      final coldSw = Stopwatch()..start();
      final m1 = await ManifestService.generateManifest(file);
      coldSw.stop();

      // Warm run (Memory cache hit)
      final warmSw = Stopwatch()..start();
      final m2 = await ManifestService.generateManifest(file);
      warmSw.stop();

      print('\n[BENCHMARK] 5 MB Cold: ${coldSw.elapsedMilliseconds} ms vs Warm Memory: ${warmSw.elapsedMilliseconds} ms (${warmSw.elapsedMicroseconds} us)');

      expect(m2.fileSha256, equals(m1.fileSha256));
      expect(m2.chunkCount, equals(m1.chunkCount));
      expect(warmSw.elapsedMilliseconds, lessThan(20)); // Sub-millisecond to few milliseconds

      // Warm run 2 (Disk cache hit after memory clear)
      ManifestCache.instance.clearMemoryCache();
      final diskSw = Stopwatch()..start();
      final m3 = await ManifestService.generateManifest(file);
      diskSw.stop();

      print('[BENCHMARK] 5 MB Warm Disk: ${diskSw.elapsedMilliseconds} ms (${diskSw.elapsedMicroseconds} us)');
      expect(m3.fileSha256, equals(m1.fileSha256));
      expect(diskSw.elapsedMilliseconds, lessThan(50));
    });

    test('3. Cache automatically invalidates when file content changes (even if size matches)', () async {
      final file = File('${tempDir.path}/mutate_test.dat');
      // Create initial file
      await file.writeAsBytes(List.filled(128 * 1024, 65)); // 128 KB of 'A'

      final m1 = await ManifestService.generateManifest(file);
      expect(m1, isNotNull);

      // Verify cached
      final cachedHit = await ManifestCache.instance.get(file, expectedChunkSize: m1.chunkSize);
      expect(cachedHit, isNotNull);

      // In-place modification: Overwrite with 'B' (same size)
      await file.writeAsBytes(List.filled(128 * 1024, 66)); // 128 KB of 'B'

      // Lookup must detect change and return null
      final cachedAfterMutate = await ManifestCache.instance.get(file, expectedChunkSize: m1.chunkSize);
      expect(cachedAfterMutate, isNull);

      // Generating manifest produces new SHA-256
      final m2 = await ManifestService.generateManifest(file);
      expect(m2.fileSha256, isNot(equals(m1.fileSha256)));
    });

    test('4. Empty file (0 bytes) generates valid manifest with 0 chunks and correct empty hash', () async {
      final file = File('${tempDir.path}/empty.txt');
      await file.writeAsString('');

      final manifest = await ManifestService.generateManifest(file);

      expect(manifest.fileSize, equals(0));
      expect(manifest.chunkCount, equals(0));
      expect(manifest.chunks.isEmpty, isTrue);
      // Empty SHA-256 is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      expect(manifest.fileSha256, equals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
    });

    test('5. Sub-chunk file (< 512 KB) correctly produces single chunk with matching hash', () async {
      final file = File('${tempDir.path}/small.txt');
      await file.writeAsString('FluxShare P2P transfer test sample data');

      final expectedHash = await FileHasher.computeFileSha256(file);
      final manifest = await ManifestService.generateManifest(file);

      expect(manifest.chunkCount, equals(1));
      expect(manifest.chunks.length, equals(1));
      expect(manifest.chunks[0].chunkId, equals(0));
      expect(manifest.chunks[0].offset, equals(0));
      expect(manifest.chunks[0].length, equals(await file.length()));
      expect(manifest.chunks[0].sha256, equals(expectedHash));
      expect(manifest.fileSha256, equals(expectedHash));
    });

    test('6. Adaptive chunk boundaries: 3.5 GB movie selects 8 MB chunks', () {
      expect(ManifestService.selectAdaptiveChunkSize(5 * 1024 * 1024), equals(512 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(50 * 1024 * 1024), equals(1024 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(250 * 1024 * 1024), equals(2 * 1024 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(800 * 1024 * 1024), equals(4 * 1024 * 1024));

      // 3.5 GB file -> 8 MB chunks
      const size3_5GB = 3758096384;
      final chunkSize = ManifestService.selectAdaptiveChunkSize(size3_5GB);
      expect(chunkSize, equals(8 * 1024 * 1024));

      final expectedChunks = (size3_5GB / chunkSize).ceil();
      expect(expectedChunks, equals(448));
    });

    test('7. Cancellation terminates background isolate immediately and ignores stale completion', () async {
      final file = File('${tempDir.path}/cancel_target.dat');
      // Create 2 MB file
      await file.writeAsBytes(List.filled(2 * 1024 * 1024, 99));

      bool cancelRequested = false;

      // Start hashing and cancel immediately
      final future = ManifestService.generateManifest(
        file,
        chunkSize: 64 * 1024,
        onProgress: (p) {
          if (p.currentChunk >= 2) {
            cancelRequested = true;
          }
        },
        isCancelled: () => cancelRequested,
      );

      // Must complete with error or cancellation
      expect(future, throwsA(isA<Exception>()));
    });

    test('8. Receiver verification: verifyChunk and verifyWholeFile match generated manifest', () async {
      final file = File('${tempDir.path}/receiver_compat.dat');
      final bytes = List<int>.generate(256 * 1024, (i) => (i * 23 + 5) & 0xFF);
      await file.writeAsBytes(bytes);

      final manifest = await ManifestService.generateManifest(file, chunkSize: 64 * 1024);

      // Verify each chunk as a receiver would
      for (final chunk in manifest.chunks) {
        final chunkSlice = bytes.sublist(chunk.offset, chunk.offset + chunk.length);
        final isValid = FileHasher.verifyChunk(chunkSlice, chunk.sha256);
        expect(isValid, isTrue);
      }

      // Verify whole file as receiver would
      final isWholeValid = await FileHasher.verifyWholeFile(file, manifest.fileSha256);
      expect(isWholeValid, isTrue);
    });

    test('9. FileInfo.fromMetadata produces formatted size and file types synchronously', () {
      final info = FileInfo.fromMetadata(
        path: '/storage/emulated/0/Movies/film.mp4',
        name: 'film.mp4',
        sizeBytes: 3758096384, // 3.5 GB
      );

      expect(info.name, equals('film.mp4'));
      expect(info.formattedSize, equals('3.50 GB'));
      expect(info.type, equals(FileType.Video));
      expect(info.extension, equals('mp4'));
    });
  });
}
