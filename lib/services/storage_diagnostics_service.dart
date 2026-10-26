import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Service for monitoring storage footprint, available destination space,
/// and safe temporary file lifecycle management.
class StorageDiagnosticsService {
  static final StorageDiagnosticsService _instance =
      StorageDiagnosticsService._internal();
  factory StorageDiagnosticsService() => _instance;
  StorageDiagnosticsService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.example.fluxshare/background_service');

  @visibleForTesting
  static Future<int> Function(String path)? customAvailableStorageHandler;

  final Set<String> _activeTempFiles = {};
  int _totalBytesCopiedToTemp = 0;
  int _totalTempFilesReused = 0;

  int get totalBytesCopiedToTemp => _totalBytesCopiedToTemp;
  int get totalTempFilesReused => _totalTempFilesReused;
  Set<String> get activeTempFiles => Set.unmodifiable(_activeTempFiles);

  /// Registers an active temporary file owned by FluxShare.
  void registerTempFile(String path, int sizeBytes) {
    _activeTempFiles.add(path);
    _totalBytesCopiedToTemp += sizeBytes;
    debugPrint('[FluxShare-Storage] Registered managed temp file: $path ($sizeBytes bytes)');
  }

  /// Marks an existing temporary file as reused to avoid copying duplicate bytes.
  void markTempFileReused(String path) {
    _totalTempFilesReused++;
    debugPrint('[FluxShare-Storage] Reused existing temp file without copying: $path');
  }

  /// Unregisters and safely deletes an owned temporary file.
  Future<void> releaseTempFile(String path) async {
    _activeTempFiles.remove(path);
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[FluxShare-Storage] Released and deleted managed temp file: $path');
      }
    } catch (e) {
      debugPrint('[FluxShare-Storage] Error deleting temp file $path: $e');
    }
  }

  /// Queries real operating-system available storage bytes for the given target path.
  Future<int?> getAvailableStorageBytes(String path) async {
    if (customAvailableStorageHandler != null) {
      return customAvailableStorageHandler!(path);
    }

    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<int>(
          'getAvailableStorageBytes',
          {'path': path},
        );
        return result;
      } catch (e) {
        debugPrint('[FluxShare-Storage] Native StatFs call error: $e');
      }
    }
    return null;
  }

  /// Calculates total size in bytes of files in the given directory matching optional prefix.
  static Future<int> getDirectorySizeBytes(
    Directory dir, {
    String? prefix,
  }) async {
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          if (prefix != null &&
              !entity.uri.pathSegments.last.startsWith(prefix)) {
            continue;
          }
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  void registerManagedTempFile(String path, [int sizeBytes = 0]) => registerTempFile(path, sizeBytes);

  bool isManagedTempFile(String path) =>
      _activeTempFiles.contains(path) ||
      path.contains('fluxshare_tmp_') ||
      path.contains('fs_managed_');

  Future<int> cleanupManagedTempFiles({Directory? customTempDir, Duration? olderThan}) =>
      cleanStaleManagedTempFiles(targetDir: customTempDir, maxAge: olderThan ?? const Duration(hours: 24));

  Future<bool> checkSufficientStorage({
    required int totalBytes,
    String? targetDirectoryPath,
    int safetyBufferBytes = 20 * 1024 * 1024,
  }) async {
    final path = targetDirectoryPath ?? (await getTemporaryDirectory()).path;
    final available = await getAvailableStorageBytes(path);
    if (available == null) return true; // Could not query or desktop, proceed
    return available >= (totalBytes + safetyBufferBytes);
  }

  /// Scans for and safely cleans up stale FluxShare temporary files.
  /// Never touches files not owned by FluxShare (only files prefixed with 'fluxshare_tmp_').
  Future<int> cleanStaleManagedTempFiles({
    Duration maxAge = const Duration(hours: 12),
    Directory? targetDir,
  }) async {
    int bytesFreed = 0;
    try {
      final tempDir = targetDir ?? await getTemporaryDirectory();
      if (!await tempDir.exists()) return 0;

      final now = DateTime.now();
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          final isFluxShareTemp = fileName.startsWith('fluxshare_tmp_') ||
              fileName.startsWith('fs_managed_');
          if (isFluxShareTemp && !_activeTempFiles.contains(entity.path)) {
            try {
              final stat = await entity.stat();
              if (now.difference(stat.modified) > maxAge) {
                final size = stat.size;
                await entity.delete();
                bytesFreed += size;
                debugPrint('[FluxShare-Storage] Cleaned stale temp file: ${entity.path} ($size bytes)');
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[FluxShare-Storage] cleanStaleManagedTempFiles error: $e');
    }
    return bytesFreed;
  }
}
