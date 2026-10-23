import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/chunk.dart';
import '../models/manifest.dart';
import 'file_hasher.dart';

/// Service for generating Manifests with adaptive chunk sizing and cryptographic hashing.
class ManifestService {
  static const int defaultChunkSize = 1024 * 1024; // 1 MB fallback
  static const _uuid = Uuid();

  /// Picks optimal chunk size based on file size to maximize throughput:
  /// - Fine-grained chunks for small files (faster initial progress display)
  /// - Larger chunks for large files (reduces HTTP request/header overhead)
  static int selectAdaptiveChunkSize(int fileSize) {
    if (fileSize <= 10 * 1024 * 1024) {
      return 512 * 1024; // 512 KB
    } else if (fileSize <= 100 * 1024 * 1024) {
      return 1024 * 1024; // 1 MB
    } else if (fileSize <= 500 * 1024 * 1024) {
      return 2 * 1024 * 1024; // 2 MB
    } else if (fileSize <= 1024 * 1024 * 1024) {
      return 4 * 1024 * 1024; // 4 MB
    } else {
      return 8 * 1024 * 1024; // 8 MB
    }
  }

  /// Generates a complete Manifest from a local file.
  static Future<Manifest> generateManifest(
    File file, {
    int? chunkSize,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.last;
    final fileId = _uuid.v4();

    // Select adaptive chunk size if not explicitly specified
    final effectiveChunkSize = chunkSize ?? selectAdaptiveChunkSize(fileSize);

    // Compute whole file SHA-256 asynchronously off main isolate
    final fileSha256 = await FileHasher.computeFileSha256(file);

    // Compute chunk metadata
    final List<ChunkMeta> chunks = [];
    final raf = await file.open(mode: FileMode.read);

    try {
      int chunkId = 0;
      int offset = 0;

      while (offset < fileSize) {
        final length = (offset + effectiveChunkSize <= fileSize)
            ? effectiveChunkSize
            : (fileSize - offset);
        await raf.setPosition(offset);
        final bytes = await raf.read(length);
        final chunkSha256 = FileHasher.computeBytesSha256(bytes);

        chunks.add(ChunkMeta(
          chunkId: chunkId,
          offset: offset,
          length: length,
          sha256: chunkSha256,
        ));

        chunkId++;
        offset += length;
      }
    } finally {
      await raf.close();
    }

    final mimeType = detectMimeType(fileName);

    return Manifest(
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      chunkSize: effectiveChunkSize,
      chunkCount: chunks.length,
      fileSha256: fileSha256,
      chunks: chunks,
    );
  }

  /// Alias for generateManifest
  static Future<Manifest> createManifest(File file, {int? chunkSize}) =>
      generateManifest(file, chunkSize: chunkSize);

  static String detectMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'log':
      case 'md':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}
