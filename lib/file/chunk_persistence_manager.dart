import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Manages disk-persisted checkpoints of verified chunks for resumable P2P transfers.
/// Enables seamless resumption across network drops, screen-off suspension, or app restarts.
class ChunkPersistenceManager {
  static final ChunkPersistenceManager _instance =
      ChunkPersistenceManager._internal();

  factory ChunkPersistenceManager() => _instance;
  ChunkPersistenceManager._internal();

  Directory? _customDirectory;

  @visibleForTesting
  void setCustomDirectory(Directory dir) {
    _customDirectory = dir;
  }

  Future<Directory> _getCheckpointDirectory() async {
    if (_customDirectory != null) {
      if (!await _customDirectory!.exists()) {
        await _customDirectory!.create(recursive: true);
      }
      return _customDirectory!;
    }
    final docDir = await getApplicationDocumentsDirectory();
    final checkpointDir =
        Directory('${docDir.path}${Platform.pathSeparator}fluxshare_checkpoints');
    if (!await checkpointDir.exists()) {
      await checkpointDir.create(recursive: true);
    }
    return checkpointDir;
  }

  File _getCheckpointFile(Directory dir, String fileId) {
    final sanitized = fileId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$sanitized.chk.json');
  }

  /// Persists the current verified chunks for [fileId].
  Future<void> saveCheckpoint({
    required String fileId,
    required String fileName,
    required String fileSha256,
    required int fileSize,
    required int totalChunks,
    required Set<int> verifiedChunks,
  }) async {
    try {
      final dir = await _getCheckpointDirectory();
      final file = _getCheckpointFile(dir, fileId);

      final payload = {
        'fileId': fileId,
        'fileName': fileName,
        'fileSha256': fileSha256,
        'fileSize': fileSize,
        'totalChunks': totalChunks,
        'verifiedChunks': verifiedChunks.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      debugPrint('[ChunkPersistenceManager] Error saving checkpoint: $e');
    }
  }

  /// Loads verified chunks for [fileId] if a valid checkpoint matching [fileSha256] exists.
  Future<Set<int>?> loadCheckpoint({
    required String fileId,
    required String fileSha256,
  }) async {
    try {
      final dir = await _getCheckpointDirectory();
      final file = _getCheckpointFile(dir, fileId);

      if (!await file.exists()) {
        return null;
      }

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      if (data['fileSha256'] != fileSha256) {
        // Stale or mismatched manifest hash
        await file.delete();
        return null;
      }

      final rawList = data['verifiedChunks'] as List<dynamic>?;
      if (rawList == null) return null;

      final result = rawList.cast<int>().toSet();
      return result;
    } catch (e) {
      debugPrint('[ChunkPersistenceManager] Error reading checkpoint: $e');
      return null;
    }
  }

  /// Removes the checkpoint when transfer passes full 3-tier integrity verification.
  Future<void> deleteCheckpoint(String fileId) async {
    try {
      final dir = await _getCheckpointDirectory();
      final file = _getCheckpointFile(dir, fileId);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[ChunkPersistenceManager] Error deleting checkpoint: $e');
    }
  }
}
