import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';

/// Offloaded hashing utility to prevent stalling main event loop and WebSocket heartbeats.
class FileHasher {
  /// Computes SHA-256 from a raw byte slice.
  static String computeBytesSha256(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Streams whole-file bytes in a background isolate without blocking the main event loop.
  static Future<String> computeFileSha256(File file) async {
    final path = file.path;
    return await Isolate.run(() async {
      final f = File(path);
      if (!await f.exists()) {
        throw FileSystemException('File does not exist', path);
      }
      final output = await sha256.bind(f.openRead()).first;
      return output.toString();
    });
  }

  /// Verifies a chunk against expected hash.
  static bool verifyChunk(List<int> bytes, String expectedSha256) {
    final actual = computeBytesSha256(bytes);
    return actual.toLowerCase() == expectedSha256.toLowerCase();
  }

  /// Verifies whole file against expected hash in background isolate.
  static Future<bool> verifyWholeFile(File file, String expectedSha256) async {
    try {
      final actual = await computeFileSha256(file);
      return actual.toLowerCase() == expectedSha256.toLowerCase();
    } catch (_) {
      return false;
    }
  }
}
