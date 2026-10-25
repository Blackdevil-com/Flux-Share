import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/chunk.dart';
import '../models/file_info.dart';
import '../models/manifest.dart';
import 'file_hasher.dart';
import 'manifest_cache.dart';
import 'session_manifest_cache.dart';

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

  ManifestProgress({
    required this.fileId,
    required this.fileName,
    required this.bytesProcessed,
    required this.totalBytes,
    required this.progress,
    required this.stage,
    required this.currentChunk,
    required this.totalChunks,
  });

  int get percentage => (progress * 100).clamp(0, 100).toInt();
  String get formattedProcessedBytes => FileInfo.formatBytes(bytesProcessed);
  String get formattedTotalBytes => FileInfo.formatBytes(totalBytes);
}

/// Service for generating Manifests with adaptive chunk sizing, single-pass streaming,
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
  /// Uses a two-layer cache:
  /// 1. Layer B: Transfer-scoped session cache (instant in-memory hit).
  /// 2. Layer A: Persistent manifest cache (disk + LRU memory).
  ///
  /// If both layers miss, offloads hashing to a background isolate
  /// with bounded RAM usage (single chunk buffer in memory) and verifiable caching.
  static Future<Manifest> generateManifest(
    File file, {
    int? chunkSize,
    String? fileId,
    String? identifier,
    SessionManifestCache? sessionCache,
    VoidCallback? onHashingStarted,
    void Function(ManifestProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'file';
    final id = fileId ?? _uuid.v4();

    if (isCancelled?.call() == true) {
      throw const FormatException('Manifest generation cancelled');
    }

    // Select adaptive chunk size if not explicitly specified
    final effectiveChunkSize = chunkSize ?? selectAdaptiveChunkSize(fileSize);
    final totalChunks = fileSize == 0 ? 0 : (fileSize / effectiveChunkSize).ceil();

    // 1. Layer B: Check transfer-scoped session cache first
    if (sessionCache != null) {
      Manifest? sessionCached;
      try {
        sessionCached = await sessionCache.get(
          file: file,
          identity: identifier ?? file.path,
          sizeBytes: fileSize,
          chunkSize: effectiveChunkSize,
        );
      } catch (e) {
        debugPrint('[FluxShare-Cache] [Miss] layer=session, error: $e');
      }

      if (sessionCached != null) {
        debugPrint('[FluxShare-Cache] [Action] hashing_started=false, manifest_reused=true, layer=session');
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
          fileName: fileName,
          fileSize: sessionCached.fileSize,
          mimeType: sessionCached.mimeType,
          chunkSize: sessionCached.chunkSize,
          chunkCount: sessionCached.chunkCount,
          fileSha256: sessionCached.fileSha256,
          chunks: sessionCached.chunks,
        );
      }
    }

    // 2. Layer A: Check verifiable persistent manifest cache
    debugPrint('[FluxShare-Diag] [B5:CacheLookup] begin: fileId=$id, file=$fileName');
    Manifest? persistentCached;
    try {
      persistentCached = await ManifestCache.instance.get(
        file,
        identifier: identifier,
        expectedChunkSize: effectiveChunkSize,
      );
      debugPrint('[FluxShare-Diag] [B5:CacheLookup] end: fileId=$id, file=$fileName, result=${persistentCached != null ? "hit" : "miss"}');
    } catch (e) {
      debugPrint('[FluxShare-Diag] [B5:CacheLookup] end: fileId=$id, file=$fileName, result=error: $e');
    }

    if (isCancelled?.call() == true) {
      throw const FormatException('Manifest generation cancelled');
    }

    if (persistentCached != null) {
      debugPrint('[FluxShare-Cache] [Action] hashing_started=false, manifest_reused=true, layer=persistent');

      // Populate session cache with persistent hit
      if (sessionCache != null) {
        final fp = await ManifestCache.computeHeadTailFingerprint(file, fileSize) ?? '';
        sessionCache.put(
          identity: identifier ?? file.path,
          sizeBytes: fileSize,
          chunkSize: effectiveChunkSize,
          fingerprint: fp,
          manifest: persistentCached,
        );
      }

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
        fileName: fileName,
        fileSize: persistentCached.fileSize,
        mimeType: persistentCached.mimeType,
        chunkSize: persistentCached.chunkSize,
        chunkCount: persistentCached.chunkCount,
        fileSha256: persistentCached.fileSha256,
        chunks: persistentCached.chunks,
      );
    }

    // Both cache layers missed -> Notify caller that actual hashing is commencing
    onHashingStarted?.call();
    debugPrint('[FluxShare-Cache] [Action] hashing_started=true, manifest_reused=false');

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

    // Handle empty file (0 bytes) directly
    if (fileSize == 0) {
      final emptyManifest = Manifest(
        fileId: id,
        fileName: fileName,
        fileSize: 0,
        mimeType: detectMimeType(fileName),
        chunkSize: effectiveChunkSize,
        chunkCount: 0,
        fileSha256: sha256.convert(const []).toString(),
        chunks: const [],
      );
      if (sessionCache != null) {
        sessionCache.put(
          identity: identifier ?? file.path,
          sizeBytes: 0,
          chunkSize: effectiveChunkSize,
          fingerprint: 'empty',
          manifest: emptyManifest,
        );
      }
      await ManifestCache.instance.put(file, emptyManifest, identifier: identifier);
      onProgress?.call(ManifestProgress(
        fileId: id,
        fileName: fileName,
        bytesProcessed: 0,
        totalBytes: 0,
        progress: 1.0,
        stage: 'Manifest Ready',
        currentChunk: 0,
        totalChunks: 0,
      ));
      return emptyManifest;
    }

    debugPrint('[FluxShare-Diag] [B6:GenBegin] fileId=$id, file=$fileName, totalBytes=$fileSize, chunkSize=$effectiveChunkSize, totalChunks=$totalChunks');

    // 3. Offload hashing to background isolate to keep Flutter UI buttery smooth
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
      if (isCancelled?.call() == true) {
        throw const FormatException('Manifest generation cancelled');
      }

      if (sessionCache != null) {
        final fp = await ManifestCache.computeHeadTailFingerprint(file, fileSize) ?? '';
        sessionCache.put(
          identity: identifier ?? file.path,
          sizeBytes: fileSize,
          chunkSize: effectiveChunkSize,
          fingerprint: fp,
          manifest: manifest,
        );
      }
      await ManifestCache.instance.put(file, manifest, identifier: identifier);
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

      if (isCancelled?.call() == true) {
        throw const FormatException('Manifest generation cancelled');
      }

      // Store in session cache
      if (sessionCache != null) {
        final fp = await ManifestCache.computeHeadTailFingerprint(file, fileSize) ?? '';
        sessionCache.put(
          identity: identifier ?? file.path,
          sizeBytes: fileSize,
          chunkSize: effectiveChunkSize,
          fingerprint: fp,
          manifest: manifest,
        );
      }

      // Persist in verifiable cache
      await ManifestCache.instance.put(file, manifest, identifier: identifier);
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
      if (isCancelled?.call() == true) {
        throw const FormatException('Manifest generation cancelled');
      }

      if (sessionCache != null) {
        final fp = await ManifestCache.computeHeadTailFingerprint(file, fileSize) ?? '';
        sessionCache.put(
          identity: identifier ?? file.path,
          sizeBytes: fileSize,
          chunkSize: effectiveChunkSize,
          fingerprint: fp,
          manifest: manifest,
        );
      }
      await ManifestCache.instance.put(file, manifest, identifier: identifier);
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
      onError: receivePort.sendPort,
      debugName: 'FluxShareManifestWorker',
    );
    debugPrint('[FluxShare-Diag] [B7:Isolate] started: fileId=$fileId, file=$fileName');

    StreamSubscription? sub;
    Timer? poller;

    void cleanup() {
      poller?.cancel();
      sub?.cancel();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }

    if (isCancelled != null) {
      poller = Timer.periodic(const Duration(milliseconds: 30), (_) {
        if (isCancelled()) {
          debugPrint('[FluxShare-Diag] [B8:CancelAck] poller detected cancel: fileId=$fileId, file=$fileName');
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(const FormatException('Manifest generation cancelled'));
          }
        }
      });
    }

    sub = receivePort.listen((message) {
      if (message is List && message.length >= 2) {
        final err = message[0].toString();
        debugPrint('[FluxShare-Diag] [B7:Isolate] uncaught error: fileId=$fileId, file=$fileName, error=$err');
        cleanup();
        if (!completer.isCompleted) {
          completer.completeError(Exception(err));
        }
        return;
      }
      if (message is Map<String, dynamic>) {
        final type = message['type'] as String;
        if (type == 'progress') {
          if (isCancelled?.call() == true) {
            debugPrint('[FluxShare-Diag] [B8:CancelAck] progress listener detected cancel: fileId=$fileId, file=$fileName');
            cleanup();
            if (!completer.isCompleted) {
              completer.completeError(const FormatException('Manifest generation cancelled'));
            }
            return;
          }
          final offset = message['offset'] as int;
          final chunkId = message['chunkId'] as int;
          final progress = fileSize > 0 ? (offset / fileSize).clamp(0.0, 1.0) : 1.0;
          debugPrint('[FluxShare-Diag] [B7:Isolate] progress: fileId=$fileId, file=$fileName, bytes=$offset/$fileSize, progress=${(progress * 100).toStringAsFixed(1)}%');
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
          if (isCancelled?.call() == true) {
            debugPrint('[FluxShare-Diag] [B8:CancelAck] progress callback detected cancel: fileId=$fileId, file=$fileName');
            cleanup();
            if (!completer.isCompleted) {
              completer.completeError(const FormatException('Manifest generation cancelled'));
            }
            return;
          }
        } else if (type == 'done') {
          if (isCancelled?.call() == true) {
            debugPrint('[FluxShare-Diag] [B8:CancelAck] done discarded due to cancel: fileId=$fileId, file=$fileName');
            cleanup();
            if (!completer.isCompleted) {
              completer.completeError(const FormatException('Manifest generation cancelled'));
            }
            return;
          }
          final manifestJson = message['manifest'] as Map<String, dynamic>;
          final manifest = Manifest.fromJson(manifestJson);
          debugPrint('[FluxShare-Diag] [B7:Isolate] complete: fileId=$fileId, file=$fileName');
          cleanup();
          if (!completer.isCompleted) {
            completer.complete(manifest);
          }
        } else if (type == 'error') {
          final error = message['error'] as String;
          debugPrint('[FluxShare-Diag] [B7:Isolate] fail: fileId=$fileId, file=$fileName, error=$error');
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

    RandomAccessFile? raf;
    try {
      final fileSize = await file.length();
      final fileName = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'file';
      raf = await file.open(mode: FileMode.read);

      final List<ChunkMeta> chunks = [];
      final sink = _DigestSink();
      final wholeFileConversion = sha256.startChunkedConversion(sink);

      int chunkId = 0;
      int offset = 0;
      int lastReportedMs = 0;
      final sw = Stopwatch()..start();

      while (offset < fileSize) {
        final length = (offset + effectiveChunkSize <= fileSize)
            ? effectiveChunkSize
            : (fileSize - offset);

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

        // Throttle progress updates to at most once every 50ms for production chunks (>= 512 KB),
        // or emit on every chunk for fine-grained chunking / tests.
        final nowMs = sw.elapsedMilliseconds;
        final shouldReport = effectiveChunkSize < 512 * 1024 ||
            (nowMs - lastReportedMs >= 50) ||
            offset >= fileSize;
        if (shouldReport) {
          lastReportedMs = nowMs;
          sendPort.send({
            'type': 'progress',
            'offset': offset,
            'chunkId': chunkId,
          });
        }
      }

      wholeFileConversion.close();
      await raf.close();
      raf = null;

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
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
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
    RandomAccessFile? raf;

    try {
      raf = await file.open(mode: FileMode.read);
      int chunkId = 0;
      int offset = 0;

      while (offset < fileSize) {
        if (isCancelled?.call() == true) {
          throw const FormatException('Manifest generation cancelled');
        }

        final length = (offset + effectiveChunkSize <= fileSize)
            ? effectiveChunkSize
            : (fileSize - offset);

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

        if (isCancelled?.call() == true) {
          throw const FormatException('Manifest generation cancelled');
        }

        await Future<void>.value();
      }

      wholeFileConversion.close();
      await raf.close();
      raf = null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
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

    return manifest;
  }

  /// Alias for backward compatibility
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
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
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
