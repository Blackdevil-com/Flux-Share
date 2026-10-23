import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../models/chunk.dart';
import '../models/manifest.dart';
import 'file_hasher.dart';

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

/// Progress information reported during manifest generation and hashing.
class ManifestProgress {
  final String fileId;
  final String fileName;
  final int bytesProcessed;
  final int totalBytes;
  final double progress; // 0.0 to 1.0
  final String stage;
  final int currentChunk;
  final int totalChunks;

  const ManifestProgress({
    required this.fileId,
    required this.fileName,
    required this.bytesProcessed,
    required this.totalBytes,
    required this.progress,
    required this.stage,
    this.currentChunk = 0,
    this.totalChunks = 0,
  });

  String get formattedProcessedBytes => _formatBytes(bytesProcessed);
  String get formattedTotalBytes => _formatBytes(totalBytes);
  int get percentage => (progress * 100).clamp(0, 100).toInt();

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

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

  /// Generates a complete Manifest from a local file in a single streaming pass.
  /// Bounded memory usage: only single chunk buffers (<= 8 MB) are resident in RAM.
  static Future<Manifest> generateManifest(
    File file, {
    int? chunkSize,
    String? fileId,
    void Function(ManifestProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.last;
    final id = fileId ?? _uuid.v4();

    // Select adaptive chunk size if not explicitly specified
    final effectiveChunkSize = chunkSize ?? selectAdaptiveChunkSize(fileSize);
    final totalChunks = fileSize == 0 ? 0 : (fileSize / effectiveChunkSize).ceil();

    onProgress?.call(ManifestProgress(
      fileId: id,
      fileName: fileName,
      bytesProcessed: 0,
      totalBytes: fileSize,
      progress: 0.0,
      stage: 'Calculating SHA-256',
      currentChunk: 0,
      totalChunks: totalChunks,
    ));

    final List<ChunkMeta> chunks = [];
    final sink = _DigestSink();
    final wholeFileConversion = sha256.startChunkedConversion(sink);

    final raf = await file.open(mode: FileMode.read);

    try {
      int chunkId = 0;
      int offset = 0;

      while (offset < fileSize) {
        if (isCancelled?.call() == true) {
          throw const FormatException('Manifest generation cancelled');
        }

        final length = (offset + effectiveChunkSize <= fileSize)
            ? effectiveChunkSize
            : (fileSize - offset);

        await raf.setPosition(offset);
        final bytes = await raf.read(length);

        // Feed bytes into whole-file hash stream in single pass
        wholeFileConversion.add(bytes);

        // Compute chunk SHA-256
        final chunkSha256 = FileHasher.computeBytesSha256(bytes);

        chunks.add(ChunkMeta(
          chunkId: chunkId,
          offset: offset,
          length: length,
          sha256: chunkSha256,
        ));

        chunkId++;
        offset += length;

        final double currentProgress = fileSize > 0 ? (offset / fileSize).clamp(0.0, 1.0) : 1.0;
        onProgress?.call(ManifestProgress(
          fileId: id,
          fileName: fileName,
          bytesProcessed: offset,
          totalBytes: fileSize,
          progress: currentProgress,
          stage: 'Calculating SHA-256',
          currentChunk: chunkId,
          totalChunks: totalChunks,
        ));

        // Yield to event loop to preserve responsive UI and WebSocket heartbeats
        await Future<void>.delayed(Duration.zero);
      }

      wholeFileConversion.close();
    } finally {
      await raf.close();
    }

    final fileSha256 = sink.digest != null
        ? sink.digest.toString()
        : sha256.convert(const []).toString();

    final mimeType = detectMimeType(fileName);

    return Manifest(
      fileId: id,
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
  static Future<Manifest> createManifest(
    File file, {
    int? chunkSize,
    String? fileId,
    void Function(ManifestProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) =>
      generateManifest(
        file,
        chunkSize: chunkSize,
        fileId: fileId,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

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
