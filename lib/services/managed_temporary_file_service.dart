import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_diagnostics_service.dart';

/// Represents a source file tracked by FluxShare, recording whether FluxShare
/// owns it as a temporary copy or is merely referencing the original user file.
class ManagedFileReference {
  final File file;
  final String sessionId;
  final String fileId;
  final int sizeBytes;
  final bool isManaged;
  final DateTime createdAt;
  int activeReaderCount;
  bool markedForDeletion;
  String? deletionReason;

  ManagedFileReference({
    required this.file,
    required this.sessionId,
    required this.fileId,
    required this.sizeBytes,
    required this.isManaged,
    DateTime? createdAt,
    this.activeReaderCount = 0,
    this.markedForDeletion = false,
    this.deletionReason,
  }) : createdAt = createdAt ?? DateTime.now();

  String get path => file.path;
}

/// Diagnostic snapshot of managed storage usage.
class ManagedStorageUsage {
  final int totalManagedBytes;
  final int activeManagedFileCount;
  final int totalActiveReaders;
  final int totalBytesCopiedToTemp;
  final int totalFilesReused;
  final List<ManagedFileReference> managedFiles;

  const ManagedStorageUsage({
    required this.totalManagedBytes,
    required this.activeManagedFileCount,
    required this.totalActiveReaders,
    required this.totalBytesCopiedToTemp,
    required this.totalFilesReused,
    required this.managedFiles,
  });
}

/// Service providing transfer-scoped lifecycle management for temporary source files.
/// Ensures temporary files exist ONLY for the active transfer session that needs them,
/// are shared across multiple receivers without duplication, and are safely deleted
/// upon completion, cancellation, room closure, or file deselection.
class ManagedTemporaryFileService {
  static final ManagedTemporaryFileService _instance =
      ManagedTemporaryFileService._internal();

  factory ManagedTemporaryFileService() => _instance;
  static ManagedTemporaryFileService get instance => _instance;
  ManagedTemporaryFileService._internal();

  @visibleForTesting
  static Directory? customManagedTempDir;

  final Map<String, ManagedFileReference> _managedFiles = {};
  final Map<String, Set<String>> _sessionFiles = {};
  final Map<String, Future<ManagedFileReference>> _inFlightCreations = {};

  int _totalBytesCopied = 0;
  int _totalTempFilesReused = 0;

  int get totalBytesCopied => _totalBytesCopied;
  int get totalTempFilesReused => _totalTempFilesReused;
  Map<String, ManagedFileReference> get activeManagedFiles =>
      Map.unmodifiable(_managedFiles);

  @visibleForTesting
  void resetForTesting() {
    _managedFiles.clear();
    _sessionFiles.clear();
    _inFlightCreations.clear();
    _totalBytesCopied = 0;
    _totalTempFilesReused = 0;
  }

  /// Returns the dedicated directory for managed temporary files.
  Future<Directory> getManagedTempDirectory() async {
    if (customManagedTempDir != null) {
      if (!await customManagedTempDir!.exists()) {
        await customManagedTempDir!.create(recursive: true);
      }
      return customManagedTempDir!;
    }

    Directory base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}fluxshare_managed_tmp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Resolves or creates a managed temporary copy for a source file.
  /// If the original file is accessible at [path], no copy is made.
  /// If the file is streamed or content URI-based, writes atomically to a staging .part
  /// file before renaming to .tmp, preventing partial reads.
  Future<ManagedFileReference> getOrCreateManagedCopy({
    required String sessionId,
    required String fileId,
    required String name,
    required int sizeBytes,
    String? path,
    Stream<List<int>>? readStream,
    Uint8List? bytes,
    String? identifier,
  }) async {
    // 1. If original filesystem path exists and is readable, use it directly without copying
    if (path != null && path.isNotEmpty) {
      final origFile = File(path);
      if (origFile.existsSync()) {
        final ref = ManagedFileReference(
          file: origFile,
          sessionId: sessionId,
          fileId: fileId,
          sizeBytes: sizeBytes > 0 ? sizeBytes : (origFile.lengthSync()),
          isManaged: false,
        );
        _sessionFiles.putIfAbsent(sessionId, () => {}).add(origFile.path);
        _managedFiles[origFile.path] = ref;
        debugPrint('[FluxShare-Storage] Using original file directly (no temp copy): $path');
        return ref;
      }
    }

    // 2. Derive stable identity for this source
    final safeName = name.replaceAll(RegExp(r'[^\w\.-]'), '_');
    final stableKey = identifier != null
        ? sha256.convert(utf8.encode(identifier)).toString().substring(0, 16)
        : '${safeName}_$sizeBytes';

    final inFlightKey = '${sessionId}_$stableKey';
    if (_inFlightCreations.containsKey(inFlightKey)) {
      debugPrint('[FluxShare-Storage] Awaiting in-flight managed copy creation: $inFlightKey');
      return await _inFlightCreations[inFlightKey]!;
    }

    final completer = Completer<ManagedFileReference>();
    final future = completer.future;
    unawaited(future.catchError((_) => ManagedFileReference(
          file: File(''),
          sessionId: '',
          fileId: '',
          sizeBytes: 0,
          isManaged: false,
        )));
    _inFlightCreations[inFlightKey] = future;

    try {
      final managedDir = await getManagedTempDirectory();
      final finalFileName = 'fs_managed_${sessionId}_${stableKey}_$safeName.tmp';
      final finalPath = '${managedDir.path}${Platform.pathSeparator}$finalFileName';
      final finalFile = File(finalPath);

      // 3. Check if already managed in memory for this session
      final existingRef = _managedFiles[finalPath];
      if (existingRef != null && await existingRef.file.exists()) {
        _totalTempFilesReused++;
        StorageDiagnosticsService().markTempFileReused(finalPath);
        debugPrint('[FluxShare-Storage] Reusing existing in-memory managed copy: $finalPath');
        completer.complete(existingRef);
        return existingRef;
      }

      // Check if file exists on disk with matching size
      if (await finalFile.exists()) {
        final len = await finalFile.length();
        if (sizeBytes <= 0 || len == sizeBytes) {
          _totalTempFilesReused++;
          StorageDiagnosticsService().markTempFileReused(finalPath);
          final ref = ManagedFileReference(
            file: finalFile,
            sessionId: sessionId,
            fileId: fileId,
            sizeBytes: len,
            isManaged: true,
          );
          _sessionFiles.putIfAbsent(sessionId, () => {}).add(finalPath);
          _managedFiles[finalPath] = ref;
          debugPrint('[FluxShare-Storage] Reusing existing disk managed copy: $finalPath');
          completer.complete(ref);
          return ref;
        }
      }

      // 4. Staging write: create .part file first to guarantee atomic write
      final stagingFileName = 'fs_managed_${sessionId}_${stableKey}_$safeName.part';
      final stagingPath = '${managedDir.path}${Platform.pathSeparator}$stagingFileName';
      final stagingFile = File(stagingPath);
      if (await stagingFile.exists()) {
        await stagingFile.delete();
      }

      int writtenBytes = 0;
      if (readStream != null) {
        final sink = stagingFile.openWrite();
        try {
          await readStream.pipe(sink);
          await sink.flush();
          await sink.close();
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {}
          if (await stagingFile.exists()) {
            await stagingFile.delete();
          }
          rethrow;
        }
        writtenBytes = await stagingFile.length();
      } else if (bytes != null) {
        await stagingFile.writeAsBytes(bytes, flush: true);
        writtenBytes = bytes.length;
      } else {
        throw StateError('Cannot create managed copy: neither path, readStream, nor bytes provided.');
      }

      if (sizeBytes > 0 && writtenBytes != sizeBytes) {
        if (await stagingFile.exists()) await stagingFile.delete();
        throw StateError('Managed copy size mismatch: expected $sizeBytes, wrote $writtenBytes');
      }

      // Atomically promote .part to .tmp
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      final promotedFile = await stagingFile.rename(finalPath);

      _totalBytesCopied += writtenBytes;
      StorageDiagnosticsService().registerTempFile(finalPath, writtenBytes);

      final ref = ManagedFileReference(
        file: promotedFile,
        sessionId: sessionId,
        fileId: fileId,
        sizeBytes: writtenBytes,
        isManaged: true,
      );
      _sessionFiles.putIfAbsent(sessionId, () => {}).add(finalPath);
      _managedFiles[finalPath] = ref;

      debugPrint('[FluxShare-Storage] Created atomic managed temp file: $finalPath ($writtenBytes bytes) for session $sessionId');
      completer.complete(ref);
      return ref;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      unawaited(_inFlightCreations.remove(inFlightKey));
    }
  }

  /// Increments active reader count for a managed file, preventing deletion while in use.
  void registerActiveUse(String sessionId, String fileIdOrPath) {
    final ref = _findReference(sessionId, fileIdOrPath);
    if (ref != null) {
      ref.activeReaderCount++;
      debugPrint('[FluxShare-Storage] registerActiveUse: file=${ref.path}, readers=${ref.activeReaderCount}');
    }
  }

  /// Associates an additional session identifier (such as batchId) with files
  /// registered under [sourceSessionId].
  void aliasSession({
    required String sourceSessionId,
    required String targetSessionId,
  }) {
    final files = _sessionFiles[sourceSessionId];
    if (files != null) {
      _sessionFiles.putIfAbsent(targetSessionId, () => {}).addAll(files);
      debugPrint('[FluxShare-Storage] Aliased session $sourceSessionId to $targetSessionId (${files.length} files)');
    }
  }

  /// Decrements active reader count. If reader count drops to 0 and the file is marked
  /// for deletion, safely deletes the file.
  Future<void> releaseActiveUse(String sessionId, String fileIdOrPath) async {
    final ref = _findReference(sessionId, fileIdOrPath);
    if (ref != null) {
      ref.activeReaderCount = max(0, ref.activeReaderCount - 1);
      debugPrint('[FluxShare-Storage] releaseActiveUse: file=${ref.path}, readers=${ref.activeReaderCount}');
      if (ref.activeReaderCount == 0 && ref.markedForDeletion) {
        await _deleteManagedFile(ref, ref.deletionReason ?? 'last_reader_released');
      }
    }
  }

  /// Releases and deletes a specific file from a session (e.g. when removed by the user).
  Future<bool> releaseTempFileForSession(
    String sessionId,
    String fileIdOrPath, {
    required String reason,
  }) async {
    final ref = _findReference(sessionId, fileIdOrPath);
    if (ref == null) return false;

    if (!ref.isManaged) {
      _managedFiles.remove(ref.path);
      _sessionFiles[sessionId]?.remove(ref.path);
      debugPrint('[FluxShare-Storage] Unregistered original file reference: ${ref.path}');
      return true;
    }

    _sessionFiles[sessionId]?.remove(ref.path);
    if (ref.activeReaderCount > 0) {
      ref.markedForDeletion = true;
      ref.deletionReason = reason;
      debugPrint('[FluxShare-Storage] File ${ref.path} marked for deletion (active readers: ${ref.activeReaderCount})');
      return true;
    }

    await _deleteManagedFile(ref, reason);
    return true;
  }

  /// Cleans up all managed temporary files belonging to [sessionId].
  /// Never touches original files or files owned by other sessions.
  /// If an active reader is currently accessing a file, marks it for deferred deletion.
  Future<int> cleanupSession(String sessionId, {required String reason}) async {
    int bytesFreed = 0;

    // 1. Clean any incomplete staging .part files for this session
    try {
      final dir = await getManagedTempDirectory();
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is File) {
            final name = entity.uri.pathSegments.last;
            if (name.startsWith('fs_managed_${sessionId}_') && name.endsWith('.part')) {
              try {
                final len = await entity.length();
                await entity.delete();
                bytesFreed += len;
                debugPrint('[FluxShare-Storage] Deleted abandoned staging file: ${entity.path} (freed $len bytes, reason: $reason)');
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    final paths = _sessionFiles.remove(sessionId);
    if (paths == null || paths.isEmpty) {
      debugPrint('[FluxShare-Storage] cleanupSession: No registered files for session $sessionId');
      return bytesFreed;
    }

    for (final path in List.of(paths)) {
      final ref = _managedFiles[path];
      if (ref == null) continue;

      if (!ref.isManaged) {
        // Original source file: NEVER delete!
        _managedFiles.remove(path);
        debugPrint('[FluxShare-Storage] Skipped cleanup for original source file: $path');
        continue;
      }

      if (ref.activeReaderCount > 0) {
        ref.markedForDeletion = true;
        ref.deletionReason = reason;
        debugPrint('[FluxShare-Storage] Retained managed file $path during cleanup: activeReaderCount=${ref.activeReaderCount} (marked for deletion)');
      } else {
        final freed = await _deleteManagedFile(ref, reason);
        bytesFreed += freed;
      }
    }

    return bytesFreed;
  }

  /// Deletes stale managed temporary files on startup or periodic maintenance.
  /// Strictly touches ONLY files with FluxShare managed prefix ('fs_managed_' or 'fluxshare_tmp_').
  Future<int> cleanupStaleSessions({
    Duration maxAge = const Duration(hours: 6),
    Directory? customDir,
  }) async {
    int bytesFreed = 0;
    try {
      final dir = customDir ?? await getManagedTempDirectory();
      if (!await dir.exists()) return 0;

      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          final isManagedPrefix = fileName.startsWith('fs_managed_') ||
              fileName.startsWith('fluxshare_tmp_');
          if (!isManagedPrefix) continue; // Never delete unowned files

          // Skip files currently active in memory
          final ref = _managedFiles[entity.path];
          if (ref != null && ref.activeReaderCount > 0) continue;

          try {
            final stat = await entity.stat();
            final isStaging = fileName.endsWith('.part');
            if (isStaging || now.difference(stat.modified) > maxAge) {
              final size = stat.size;
              await entity.delete();
              bytesFreed += size;
              _managedFiles.remove(entity.path);
              debugPrint('[FluxShare-Storage] Cleaned stale managed temp file: ${entity.path} ($size bytes)');
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[FluxShare-Storage] cleanupStaleSessions error: $e');
    }
    return bytesFreed;
  }

  /// Returns storage usage diagnostics for all active managed files.
  Future<ManagedStorageUsage> getManagedStorageUsage() async {
    int activeBytes = 0;
    int managedCount = 0;
    int readerCount = 0;

    for (final ref in _managedFiles.values) {
      if (ref.isManaged) {
        managedCount++;
        activeBytes += ref.sizeBytes;
        readerCount += ref.activeReaderCount;
      }
    }

    return ManagedStorageUsage(
      totalManagedBytes: activeBytes,
      activeManagedFileCount: managedCount,
      totalActiveReaders: readerCount,
      totalBytesCopiedToTemp: _totalBytesCopied,
      totalFilesReused: _totalTempFilesReused,
      managedFiles: List.unmodifiable(_managedFiles.values),
    );
  }

  ManagedFileReference? _findReference(String sessionId, String fileIdOrPath) {
    if (_managedFiles.containsKey(fileIdOrPath)) {
      return _managedFiles[fileIdOrPath];
    }
    for (final ref in _managedFiles.values) {
      if (ref.sessionId == sessionId &&
          (ref.fileId == fileIdOrPath || ref.path == fileIdOrPath)) {
        return ref;
      }
    }
    return null;
  }

  Future<int> _deleteManagedFile(ManagedFileReference ref, String reason) async {
    _managedFiles.remove(ref.path);
    int freed = 0;
    try {
      if (await ref.file.exists()) {
        freed = await ref.file.length();
        await ref.file.delete();
        debugPrint('[FluxShare-Storage] Deleted managed temp file: ${ref.path} (freed $freed bytes, reason: $reason)');
      }
      await StorageDiagnosticsService().releaseTempFile(ref.path);
    } catch (e) {
      debugPrint('[FluxShare-Storage] Error deleting managed temp file ${ref.path}: $e');
    }
    return freed;
  }
}
