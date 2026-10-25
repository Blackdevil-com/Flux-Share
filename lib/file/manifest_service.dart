import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/chunk.dart';
import '../models/manifest.dart';
import 'file_hasher.dart';
import 'manifest_cache.dart';

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

/// Service for generating Manifests with adaptive chunk sizing, cryptographic hashing,
/// background isolate execution, and persistent manifest caching.
class ManifestService {
  static const int defaultChunkSize = 1024 * 1024; // 1 MB fallback
  static const _uuid = Uuid();

  @visibleForTesting
  static bool disableIsolatesForTesting = false;

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
  /// Uses a background isolate so the main UI thread never blocks during multi-GB hashing,
  /// with bounded RAM usage (single chunk buffer in memory) and verifiable caching.
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

    // 1. Check verifiable manifest cache first (instant hit for unmodified files)
    final cached = await ManifestCache.instance.get(file, expectedChunkSize: effectiveChunkSize);
    if (cached != null) {
      onProgress?.call(ManifestProgress(
        fileId: id,
        fileName: fileName,
        bytesProcessed: fileSize,
        totalBytes: fileSize,
        progress: 1.0,
        stage: 'Manifest Ready',
        currentChunk: totalChunks,
        totalChunks: totalChunks,
      ));
      return Manifest(
        fileId: id,
        fileName: cached.fileName,
        fileSize: cached.fileSize,
        mimeType: cached.mimeType,
        chunkSize: cached.chunkSize,
        chunkCount: cached.chunkCount,
        fileSha256: cached.fileSha256,
        chunks: cached.chunks,
      );
    }

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

    // 2. Offload hashing to background isolate to keep Flutter UI buttery smooth
    // If isolates are disabled for test environments, run in-process streaming
    if (disableIsolatesForTesting) {
      final manifest = await _hashInProcess(
        file: file,
        fileId: id,
        fileName: fileName,
        fileSize: fileSize,
        effectiveChunkSize: effectiveChunkSize,
        totalChunks: totalChunks,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      await ManifestCache.instance.put(file, manifest);
      return manifest;
    }

    try {
      final manifest = await _hashInIsolate(
        filePath: file.path,
        fileId: id,
        fileName: fileName,
        fileSize: fileSize,
        effectiveChunkSize: effectiveChunkSize,
        totalChunks: totalChunks,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

      // Persist in verifiable cache
      await ManifestCache.instance.put(file, manifest);
      return manifest;
    } catch (e) {
      if (e is FormatException) rethrow;
      // Fallback to in-process single-pass streaming if isolate spawning fails
      final manifest = await _hashInProcess(
        file: file,
        fileId: id,
        fileName: fileName,
        fileSize: fileSize,
        effectiveChunkSize: effectiveChunkSize,
        totalChunks: totalChunks,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      await ManifestCache.instance.put(file, manifest);
      return manifest;
    }
  }

  static Future<Manifest> _hashInIsolate({
    required String filePath,
    required String fileId,
    required String fileName,
    required int fileSize,
    required int effectiveChunkSize,
    required int totalChunks,
    void Function(ManifestProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final receivePort = ReceivePort();
    final completer = Completer<Manifest>();

    final isolate = await Isolate.spawn(
      _isolateHashingWorker,
      [filePath, fileId, effectiveChunkSize, receivePort.sendPort],
      debugName: 'FluxShareManifestWorker',
    );

    StreamSubscription? sub;
    Timer? cancellationPoller;

    void cleanup() {
      cancellationPoller?.cancel();
      sub?.cancel();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }

    if (isCancelled != null) {
      cancellationPoller = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (isCancelled()) {
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(const FormatException('Manifest generation cancelled'));
          }
        }
      });
    }

    sub = receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String;
        if (type == 'progress') {
          if (isCancelled?.call() == true) {
            cleanup();
            if (!completer.isCompleted) {
              completer.completeError(const FormatException('Manifest generation cancelled'));
            }
            return;
          }
          final offset = message['offset'] as int;
          final chunkId = message['chunkId'] as int;
          final progress = fileSize > 0 ? (offset / fileSize).clamp(0.0, 1.0) : 1.0;
          onProgress?.call(ManifestProgress(
            fileId: fileId,
            fileName: fileName,
            bytesProcessed: offset,
            totalBytes: fileSize,
            progress: progress,
            stage: 'Calculating SHA-256',
            currentChunk: chunkId,
            totalChunks: totalChunks,
          ));
        } else if (type == 'done') {
          final manifestJson = message['manifest'] as Map<String, dynamic>;
          final manifest = Manifest.fromJson(manifestJson);
          cleanup();
          if (!completer.isCompleted) {
            completer.complete(manifest);
          }
        } else if (type == 'error') {
          final error = message['error'] as String;
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(Exception(error));
          }
        }
      }
    });

    return completer.future;
  }

  static void _isolateHashingWorker(List<dynamic> args) async {
    final String filePath = args[0] as String;
    final String fileId = args[1] as String;
    final int effectiveChunkSize = args[2] as int;
    final SendPort sendPort = args[3] as SendPort;

    final file = File(filePath);
    if (!await file.exists()) {
      sendPort.send({'type': 'error', 'error': 'File not found: $filePath'});
      return;
    }

    try {
      final fileSize = await file.length();
      final fileName = file.uri.pathSegments.last;
      final raf = await file.open(mode: FileMode.read);

      final List<ChunkMeta> chunks = [];
      final sink = _DigestSink();
      final wholeFileConversion = sha256.startChunkedConversion(sink);

      int chunkId = 0;
      int offset = 0;

      try {
        while (offset < fileSize) {
          final length = (offset + effectiveChunkSize <= fileSize)
              ? effectiveChunkSize
              : (fileSize - offset);

          await raf.setPosition(offset);
          final bytes = await raf.read(length);

          wholeFileConversion.add(bytes);
          final chunkSha256 = FileHasher.computeBytesSha256(bytes);

          chunks.add(ChunkMeta(
            chunkId: chunkId,
            offset: offset,
            length: length,
            sha256: chunkSha256,
          ));

          chunkId++;
          offset += length;

          sendPort.send({
            'type': 'progress',
            'offset': offset,
            'chunkId': chunkId,
          });
        }

        wholeFileConversion.close();
      } finally {
        await raf.close();
      }

      final fileSha256 = sink.digest != null
          ? sink.digest.toString()
          : sha256.convert(const []).toString();

      final mimeType = detectMimeType(fileName);

      final manifest = Manifest(
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        chunkSize: effectiveChunkSize,
        chunkCount: chunks.length,
        fileSha256: fileSha256,
        chunks: chunks,
      );

      sendPort.send({
        'type': 'done',
        'manifest': manifest.toJson(),
      });
    } catch (e) {
      sendPort.send({'type': 'error', 'error': e.toString()});
    }
  }

  static Future<Manifest> _hashInProcess({
    required File file,
    required String fileId,
    required String fileName,
    required int fileSize,
    required int effectiveChunkSize,
    required int totalChunks,
    void Function(ManifestProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
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

        wholeFileConversion.add(bytes);
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
          fileId: fileId,
          fileName: fileName,
          bytesProcessed: offset,
          totalBytes: fileSize,
          progress: currentProgress,
          stage: 'Calculating SHA-256',
          currentChunk: chunkId,
          totalChunks: totalChunks,
        ));

        await Future<void>.value();
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
      case 'mkv':
      case 'avi':
      case 'mov':
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
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return 'application/zip';
      case 'mp3':
      case 'wav':
      case 'm4a':
      case 'flac':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }
}
