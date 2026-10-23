import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_hasher.dart';
import 'package:fluxshare/file/manifest_service.dart';

void main() {
  group('Transfer Integrity & Manifest Tests', () {
    late Directory tempDir;
    late File testFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fluxshare_test_');
      testFile = File('${tempDir.path}/test_payload.txt');
      await testFile.writeAsString('Hello FluxShare P2P Cooperative File Transfer System!');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Computes streaming whole-file SHA-256 correctly', () async {
      final hash = await FileHasher.computeFileSha256(testFile);
      expect(hash, isNotEmpty);
      expect(hash.length, equals(64)); // 64 hex characters
    });

    test('Generates manifest with valid chunks matching file size', () async {
      final manifest = await ManifestService.createManifest(testFile, chunkSize: 16);

      expect(manifest.fileName, equals('test_payload.txt'));
      expect(manifest.fileSize, equals(await testFile.length()));
      expect(manifest.chunks, isNotEmpty);

      // Verify each chunk byte slice matches its chunk SHA-256
      final bytes = await testFile.readAsBytes();
      int totalChunkBytes = 0;

      for (final chunk in manifest.chunks) {
        final slice = bytes.sublist(chunk.offset, chunk.offset + chunk.length);
        final verified = FileHasher.verifyChunk(slice, chunk.sha256);
        expect(verified, isTrue, reason: 'Chunk ${chunk.chunkId} hash verification failed');
        totalChunkBytes += chunk.length;
      }

      expect(totalChunkBytes, equals(manifest.fileSize));
    });
  });
}
