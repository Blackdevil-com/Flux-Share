import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/manifest.dart';

/// Secure, verifiable manifest cache.
/// Prevents re-hashing multi-gigabyte files when their path, size,
/// and last-modified timestamp have not changed.
class ManifestCache {
  static final ManifestCache _instance = ManifestCache._internal();
  factory ManifestCache() => _instance;
  static ManifestCache get instance => _instance;

  ManifestCache._internal();

  final Map<String, Manifest> _memoryCache = {};
  Directory? _customCacheDir;

  @visibleForTesting
  void setCustomCacheDir(Directory dir) {
    _customCacheDir = dir;
  }

  @visibleForTesting
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  String _generateKey(String path, int size, int lastModifiedMs) {
    final normalized = path.replaceAll('\\', '/');
    return '$normalized:$size:$lastModifiedMs';
  }

  Future<File?> _getCacheFile() async {
    try {
      Directory dir;
      if (_customCacheDir != null) {
        dir = _customCacheDir!;
      } else {
        dir = await getApplicationDocumentsDirectory();
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File('${dir.path}${Platform.pathSeparator}manifest_cache.json');
    } catch (_) {
      return null;
    }
  }

  /// Looks up a cached manifest for [file] if size and lastModified timestamp match.
  Future<Manifest?> get(File file, {int? expectedChunkSize}) async {
    try {
      if (!await file.exists()) return null;
      final length = await file.length();
      final lastModified = (await file.lastModified()).millisecondsSinceEpoch;
      final key = _generateKey(file.path, length, lastModified);

      // Check memory cache first
      if (_memoryCache.containsKey(key)) {
        final m = _memoryCache[key]!;
        if (expectedChunkSize == null || m.chunkSize == expectedChunkSize) {
          return m;
        }
      }

      // Check disk cache
      final cacheFile = await _getCacheFile();
      if (cacheFile != null && await cacheFile.exists()) {
        final raw = await cacheFile.readAsString();
        final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
        if (json.containsKey(key)) {
          final manifestJson = json[key] as Map<String, dynamic>;
          final manifest = Manifest.fromJson(manifestJson);
          if (expectedChunkSize == null || manifest.chunkSize == expectedChunkSize) {
            _memoryCache[key] = manifest;
            return manifest;
          }
        }
      }
    } catch (e) {
      debugPrint('[ManifestCache] Cache lookup warning: $e');
    }
    return null;
  }

  /// Stores a verified manifest into the cache.
  Future<void> put(File file, Manifest manifest) async {
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      final lastModified = (await file.lastModified()).millisecondsSinceEpoch;
      final key = _generateKey(file.path, length, lastModified);

      _memoryCache[key] = manifest;

      final cacheFile = await _getCacheFile();
      if (cacheFile != null) {
        Map<String, dynamic> existing = {};
        if (await cacheFile.exists()) {
          try {
            final raw = await cacheFile.readAsString();
            existing = jsonDecode(raw) as Map<String, dynamic>;
          } catch (_) {
            existing = {};
          }
        }
        existing[key] = manifest.toJson();

        // Limit persisted entries to most recent 100
        if (existing.length > 100) {
          final keys = existing.keys.toList();
          for (int i = 0; i < existing.length - 100; i++) {
            existing.remove(keys[i]);
          }
        }

        await cacheFile.writeAsString(jsonEncode(existing), flush: true);
      }
    } catch (e) {
      debugPrint('[ManifestCache] Cache write warning: $e');
    }
  }

  /// Clears both memory and disk caches.
  Future<void> clear() async {
    _memoryCache.clear();
    try {
      final cacheFile = await _getCacheFile();
      if (cacheFile != null && await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (_) {}
  }
}
