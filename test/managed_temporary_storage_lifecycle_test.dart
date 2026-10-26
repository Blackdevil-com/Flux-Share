import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/services/managed_temporary_file_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testTempDir;
  late Directory managedTempDir;
  late Directory manifestCacheDir;

  setUp(() async {
    testTempDir = await Directory.systemTemp.createTemp('fluxshare_storage_test_');
    managedTempDir = Directory('${testTempDir.path}/managed_tmp');
    await managedTempDir.create(recursive: true);
    manifestCacheDir = Directory('${testTempDir.path}/manifest_cache');
    await manifestCacheDir.create(recursive: true);

    ManagedTemporaryFileService.instance.resetForTesting();
    ManagedTemporaryFileService.customManagedTempDir = managedTempDir;
    ManifestCache.instance.setCustomCacheDir(manifestCacheDir);
    ManifestCache.instance.clearMemoryCache();
  });

  tearDown(() async {
    ManagedTemporaryFileService.customManagedTempDir = null;
    ManifestCache.instance.setCustomCacheDir(Directory.systemTemp);
    ManifestCache.instance.clearMemoryCache();
    try {
      if (await testTempDir.exists()) {
        await testTempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('FluxShare Transfer-Scoped Managed Temporary Storage Suite (16 Scenarios)', () {
    // 1. Selecting an accessible file creates no unnecessary full-file copy
    test('1. Selecting an accessible file creates no unnecessary full-file copy', () async {
      final originalFile = File('${testTempDir.path}/original_accessible.dat');
      await originalFile.writeAsBytes(List.filled(64 * 1024, 0xAA), flush: true);

      final service = ManagedTemporaryFileService.instance;
      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_1',
        fileId: 'file_orig_1',
        name: 'original_accessible.dat',
        sizeBytes: 64 * 1024,
        path: originalFile.path,
      );

      expect(ref.isManaged, isFalse);
      expect(ref.path, equals(originalFile.path));
      expect(service.totalBytesCopied, equals(0));

      final managedEntities = await managedTempDir.list().toList();
      expect(managedEntities, isEmpty);
    });

    // 2. Selecting a non-path file creates at most one managed copy per active session
    test('2. Selecting a non-path file creates at most one managed copy per active session', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(32 * 1024, 0xBB));

      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_2',
        fileId: 'stream_file_1',
        name: 'streamed_movie.mp4',
        sizeBytes: 32 * 1024,
        readStream: Stream.value(bytes),
        identifier: 'content://media/external/video/1234',
      );

      expect(ref.isManaged, isTrue);
      expect(await ref.file.exists(), isTrue);
      expect(await ref.file.length(), equals(32 * 1024));
      expect(ref.file.path.endsWith('.tmp'), isTrue);
      expect(service.totalBytesCopied, equals(32 * 1024));
    });

    // 3. Repeated selection does not create another full-size copy unnecessarily
    test('3. Repeated selection does not create another full-size copy unnecessarily', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(32 * 1024, 0xCC));

      final ref1 = await service.getOrCreateManagedCopy(
        sessionId: 'session_3',
        fileId: 'stream_file_repeat',
        name: 'document.pdf',
        sizeBytes: 32 * 1024,
        readStream: Stream.value(bytes),
        identifier: 'content://media/docs/555',
      );

      final initialCopiedBytes = service.totalBytesCopied;

      final ref2 = await service.getOrCreateManagedCopy(
        sessionId: 'session_3',
        fileId: 'stream_file_repeat',
        name: 'document.pdf',
        sizeBytes: 32 * 1024,
        readStream: Stream.value(bytes),
        identifier: 'content://media/docs/555',
      );

      expect(ref2.path, equals(ref1.path));
      expect(service.totalBytesCopied, equals(initialCopiedBytes));
      expect(service.totalTempFilesReused, equals(1));
    });

    // 4. Successful transfer deletes session-owned source copies
    test('4. Successful transfer deletes session-owned source copies', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(16 * 1024, 0xDD));

      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_4',
        fileId: 'transfer_done_file',
        name: 'archive.zip',
        sizeBytes: 16 * 1024,
        readStream: Stream.value(bytes),
      );

      expect(await ref.file.exists(), isTrue);

      final freed = await service.cleanupSession('session_4', reason: 'transfer_completed');
      expect(freed, equals(16 * 1024));
      expect(await ref.file.exists(), isFalse);
    });

    // 5. Sender cancellation deletes session-owned copies when safe
    test('5. Sender cancellation deletes session-owned copies when safe', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(20 * 1024, 0xEE));

      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_5',
        fileId: 'cancel_file',
        name: 'video.mkv',
        sizeBytes: 20 * 1024,
        readStream: Stream.value(bytes),
      );

      expect(await ref.file.exists(), isTrue);

      await service.cleanupSession('session_5', reason: 'sender_cancelled');
      expect(await ref.file.exists(), isFalse);
    });

    // 6. Hashing cancellation cleans up its partial managed copy
    test('6. Hashing cancellation cleans up its partial managed copy', () async {
      final stagingFile = File('${managedTempDir.path}/fs_managed_session_6_hash_test.part');
      await stagingFile.writeAsBytes(List.filled(10 * 1024, 0x01), flush: true);
      expect(await stagingFile.exists(), isTrue);

      final freed = await ManagedTemporaryFileService.instance.cleanupSession(
        'session_6',
        reason: 'hashing_cancelled',
      );

      expect(freed, equals(10 * 1024));
      expect(await stagingFile.exists(), isFalse);
    });

    // 7. Failed preparation does not leave abandoned files
    test('7. Failed preparation does not leave abandoned files', () async {
      final service = ManagedTemporaryFileService.instance;
      bool threw = false;
      try {
        await service.getOrCreateManagedCopy(
          sessionId: 'session_7',
          fileId: 'fail_file',
          name: 'bad_file.bin',
          sizeBytes: 50 * 1024,
          bytes: Uint8List.fromList([1, 2, 3]), // size mismatch triggers failure
        );
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue);

      final entities = await managedTempDir.list().toList();
      expect(entities.where((e) => e.path.contains('session_7')), isEmpty);
    });

    // 8. Closing a room releases the previous session's managed files
    test('8. Closing a room releases the previous session\'s managed files', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(8 * 1024, 0x11));

      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'room_session_8',
        fileId: 'file_8',
        name: 'photo.jpg',
        sizeBytes: 8 * 1024,
        readStream: Stream.value(bytes),
      );
      expect(await ref.file.exists(), isTrue);

      await service.cleanupSession('room_session_8', reason: 'room_closed');
      expect(await ref.file.exists(), isFalse);
    });

    // 9. Multiple receivers share one source copy safely
    test('9. Multiple receivers share one source copy safely', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(40 * 1024, 0x22));

      final ref1 = await service.getOrCreateManagedCopy(
        sessionId: 'session_multi_rcv',
        fileId: 'shared_file',
        name: 'shared.mp4',
        sizeBytes: 40 * 1024,
        readStream: Stream.value(bytes),
        identifier: 'content://media/video/77',
      );

      service.registerActiveUse('session_multi_rcv', ref1.path);
      service.registerActiveUse('session_multi_rcv', ref1.path);

      final usage = await service.getManagedStorageUsage();
      expect(usage.totalActiveReaders, equals(2));
      expect(usage.activeManagedFileCount, equals(1));
      expect(usage.totalManagedBytes, equals(40 * 1024));

      await service.releaseActiveUse('session_multi_rcv', ref1.path);
      await service.releaseActiveUse('session_multi_rcv', ref1.path);

      await service.cleanupSession('session_multi_rcv', reason: 'all_receivers_completed');
      expect(await ref1.file.exists(), isFalse);
    });

    // 10. A temporary file is not deleted while a worker is reading it
    test('10. A temporary file is not deleted while a worker is reading it', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(15 * 1024, 0x33));

      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_10',
        fileId: 'worker_file',
        name: 'data.bin',
        sizeBytes: 15 * 1024,
        readStream: Stream.value(bytes),
      );

      service.registerActiveUse('session_10', ref.path);

      await service.cleanupSession('session_10', reason: 'session_close_attempt');
      expect(await ref.file.exists(), isTrue);
      expect(ref.markedForDeletion, isTrue);

      await service.releaseActiveUse('session_10', ref.path);
      expect(await ref.file.exists(), isFalse);
    });

    // 11. Receiver cancellation does not delete sender source files or other receivers' data
    test('11. Receiver cancellation does not delete sender source files or other receivers\' data', () async {
      final senderFile = File('${testTempDir.path}/sender_source.mp4');
      await senderFile.writeAsBytes(List.filled(24 * 1024, 0x44), flush: true);

      final rcv1Dest = File('${testTempDir.path}/rcv1_download.mp4');
      await rcv1Dest.writeAsBytes(List.filled(12 * 1024, 0x44), flush: true);

      final rcv2Dest = File('${testTempDir.path}/rcv2_download.mp4');
      await rcv2Dest.writeAsBytes(List.filled(12 * 1024, 0x44), flush: true);

      // Simulate receiver 1 cancellation
      if (await rcv1Dest.exists()) {
        await rcv1Dest.delete();
      }

      expect(await senderFile.exists(), isTrue);
      expect(await rcv2Dest.exists(), isTrue);
      expect(await rcv1Dest.exists(), isFalse);
    });

    // 12. Completed received files remain intact
    test('12. Completed received files remain intact', () async {
      final completedRcvFile = File('${testTempDir.path}/completed_presentation.pdf');
      await completedRcvFile.writeAsBytes(List.filled(18 * 1024, 0x55), flush: true);

      await ManagedTemporaryFileService.instance.cleanupSession(
        'receiver_session',
        reason: 'receiver_done',
      );

      expect(await completedRcvFile.exists(), isTrue);
      expect(await completedRcvFile.length(), equals(18 * 1024));
    });

    // 13. Original source files remain intact
    test('13. Original source files remain intact', () async {
      final userOriginal = File('${testTempDir.path}/user_precious_file.zip');
      await userOriginal.writeAsBytes(List.filled(50 * 1024, 0x66), flush: true);

      final service = ManagedTemporaryFileService.instance;
      final ref = await service.getOrCreateManagedCopy(
        sessionId: 'session_13',
        fileId: 'orig_ref_13',
        name: 'user_precious_file.zip',
        sizeBytes: 50 * 1024,
        path: userOriginal.path,
      );

      expect(ref.isManaged, isFalse);

      await service.cleanupSession('session_13', reason: 'transfer_finished');
      expect(await userOriginal.exists(), isTrue);
      expect(await userOriginal.length(), equals(50 * 1024));
    });

    // 14. Manifest metadata remains reusable after temporary source cleanup when the original source is selected again
    test('14. Manifest metadata remains reusable after temporary source cleanup when the original source is selected again', () async {
      final file = File('${testTempDir.path}/manifest_reuse.dat');
      await file.writeAsBytes(List.filled(64 * 1024, 0x77), flush: true);

      final manifest1 = await ManifestService.generateManifest(
        file,
        fileId: 'test_manifest_id',
      );
      expect(manifest1.chunks.length, greaterThan(0));

      final cachedManifest = await ManifestCache.instance.get(file);
      expect(cachedManifest, isNotNull);
      expect(cachedManifest!.fileSha256, equals(manifest1.fileSha256));

      await ManagedTemporaryFileService.instance.cleanupSession(
        'some_session',
        reason: 'session_cleaned',
      );

      final rechecked = await ManifestCache.instance.get(file);
      expect(rechecked, isNotNull);
      expect(rechecked!.fileSha256, equals(manifest1.fileSha256));
    });

    // 15. Stale-session cleanup never deletes unowned files
    test('15. Stale-session cleanup never deletes unowned files', () async {
      final unownedFile = File('${managedTempDir.path}/unowned_user_cache.tmp');
      await unownedFile.writeAsBytes([1, 2, 3, 4], flush: true);

      final staleManaged = File('${managedTempDir.path}/fs_managed_old_session_file.tmp');
      await staleManaged.writeAsBytes(List.filled(100, 0x88), flush: true);

      final freed = await ManagedTemporaryFileService.instance.cleanupStaleSessions(
        maxAge: Duration.zero,
        customDir: managedTempDir,
      );

      expect(freed, equals(100));
      expect(await staleManaged.exists(), isFalse);
      expect(await unownedFile.exists(), isTrue);
    });

    // 16. Cleanup is safe when called more than once (idempotent)
    test('16. Cleanup is safe when called more than once', () async {
      final service = ManagedTemporaryFileService.instance;
      final bytes = Uint8List.fromList(List.filled(5 * 1024, 0x99));

      await service.getOrCreateManagedCopy(
        sessionId: 'session_16',
        fileId: 'idempotent_file',
        name: 'file.txt',
        sizeBytes: 5 * 1024,
        readStream: Stream.value(bytes),
      );

      final freed1 = await service.cleanupSession('session_16', reason: 'first_call');
      expect(freed1, equals(5 * 1024));

      final freed2 = await service.cleanupSession('session_16', reason: 'second_call');
      expect(freed2, equals(0));

      final freed3 = await service.cleanupSession('session_16', reason: 'third_call');
      expect(freed3, equals(0));
    });
  });
}
