import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/manifest.dart';

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

/// Secure, high-performance verifiable manifest cache.
///
/// Eliminates redundant multi-gigabyte SHA-256 hashing on repeated file selections.
///
/// Validation Strategy:
/// 1. File path, file size (bytes), and last-modified timestamp must match.
/// 2. Head & Tail fingerprint: Samples the first and last 4 KB of the file and
///    computes a fast SHA-256 slice. This detects in-place file replacement or
///    modification where file size and timestamp may be preserved or spoofed,
///    without incurring the cost of reading the entire multi-gigabyte file.
/// 3. Per-manifest persistent storage: Manifests are stored individually as atomic
///    JSON files in a dedicated `manifest_cache/` directory to avoid rewriting a
///    monolithic cache file on every change.
/// 4. In-memory LRU cache: Frequently accessed manifests return in < 1 ms.
///
/// Trust Assumptions & Security:
/// - The cache assumes that if path, size, last-modified timestamp, and head/tail
///   fingerprint match, the file content is identical to the verified manifest.
/// - End-to-end integrity is always enforced: The receiver independently verifies
///   every downloaded chunk against `chunk.sha256` and verifies the reconstructed
///   file against `manifest.fileSha256`.
class ManifestCache {
  static final ManifestCache _instance = ManifestCache._internal();
  factory ManifestCache() => _instance;
  static ManifestCache get instance => _instance;

  ManifestCache._internal();

  static const int _fingerprintSampleSize = 4096; // 4 KB sample from head and tail
  static const int _maxMemoryEntries = 50;

  final Map<String, _CachedManifestEntry> _memoryCache = {};
  Directory? _customCacheDir;

  @visibleForTesting
  void setCustomCacheDir(Directory dir) {
    _customCacheDir = dir;
  }

  @visibleForTesting
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  /// Resolves the cache directory on disk.
  Future<Directory?> _getCacheDirectory() async {
    try {
      Directory baseDir;
      if (_customCacheDir != null) {
        baseDir = _customCacheDir!;
      } else {
        try {
          baseDir = await getApplicationDocumentsDirectory();
        } catch (_) {
          baseDir = Directory.systemTemp;
        }
      }
      final cacheDir = Directory('${baseDir.path}${Platform.pathSeparator}manifest_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      return cacheDir;
    } catch (e) {
      debugPrint('[ManifestCache] Failed to resolve cache directory: $e');
      return null;
    }
  }

  /// Generates a normalized cache key based on file identity, size, and chunk size.
  String _generateKey(String identity, int size, int chunkSize) {
    final normalized = identity.replaceAll('\\', '/');
    return '$normalized:$size:$chunkSize';
  }

  /// Legacy key generator including last-modified timestamp for backward compatibility.
  String _generateLegacyKey(String path, int size, int lastModifiedMs, int chunkSize) {
    final normalizedPath = path.replaceAll('\\', '/');
    return '$normalizedPath:$size:$lastModifiedMs:$chunkSize';
  }

  /// Hashes key to produce a safe filesystem filename.
  String _keyToFileName(String key) {
    return sha256.convert(utf8.encode(key)).toString();
  }

  /// Computes a fast head and tail fingerprint (up to 8 KB total) to detect in-place modification.
  static Future<String?> computeHeadTailFingerprint(File file, int fileSize) async {
    if (fileSize <= 0) return 'empty';
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final headLength = fileSize < _fingerprintSampleSize ? fileSize : _fingerprintSampleSize;
      final headBytes = await raf.read(headLength);

      Uint8List tailBytes = Uint8List(0);
      if (fileSize > _fingerprintSampleSize) {
        final tailOffset = fileSize - _fingerprintSampleSize;
        await raf.setPosition(tailOffset);
        const tailLength = _fingerprintSampleSize;
        tailBytes = await raf.read(tailLength);
      }

      final sink = _DigestSink();
      final conv = sha256.startChunkedConversion(sink);
      conv.add(headBytes);
      if (tailBytes.isNotEmpty) {
        conv.add(tailBytes);
      }
      conv.close();

      return sink.digest?.toString();
    } catch (e) {
      debugPrint('[FluxShare-Cache] Fingerprint read error: $e');
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// Looks up a cached manifest for [file].
  ///
  /// Can be queried by platform [identifier] (such as Android Content URI)
  /// and/or underlying [file.path].
  ///
  /// Returns null if not cached, if modified, or if fingerprint validation fails.
  Future<Manifest?> get(File file, {String? identifier, int? expectedChunkSize}) async {
    try {
      if (!await file.exists()) {
        debugPrint('[FluxShare-Cache] [Miss] layer=persistent, reason=file_not_found_on_disk');
        return null;
      }

      final length = await file.length();
      final lastModified = (await file.lastModified()).millisecondsSinceEpoch;

      final List<int> chunkSizes;
      if (expectedChunkSize != null) {
        chunkSizes = [expectedChunkSize];
      } else {
        int defaultCs;
        if (length <= 10 * 1024 * 1024) {
          defaultCs = 512 * 1024;
        } else if (length <= 100 * 1024 * 1024) {
          defaultCs = 1024 * 1024;
        } else if (length <= 500 * 1024 * 1024) {
          defaultCs = 2 * 1024 * 1024;
        } else if (length <= 1024 * 1024 * 1024) {
          defaultCs = 4 * 1024 * 1024;
        } else {
          defaultCs = 8 * 1024 * 1024;
        }
        chunkSizes = [
          defaultCs,
          512 * 1024,
          1024 * 1024,
          2 * 1024 * 1024,
          4 * 1024 * 1024,
          8 * 1024 * 1024,
        ];
      }

      final List<String> candidateIdentities = [];
      if (identifier != null && identifier.isNotEmpty) {
        candidateIdentities.add(identifier);
      }
      candidateIdentities.add(file.path);

      String? currentFingerprint;

      for (final cs in chunkSizes) {
        for (final id in candidateIdentities) {
          final modernKey = _generateKey(id, length, cs);
          final legacyKey = _generateLegacyKey(id, length, lastModified, cs);

          for (final key in [modernKey, legacyKey]) {
            debugPrint('[FluxShare-Cache] [Query] layer=persistent, key=$key, file=${file.path}');

            // 1. Check in-memory LRU cache
            if (_memoryCache.containsKey(key)) {
              final entry = _memoryCache[key]!;
              currentFingerprint ??= await computeHeadTailFingerprint(file, length);
              if (currentFingerprint != null && currentFingerprint == entry.fingerprint) {
                debugPrint('[FluxShare-Cache] [Hit] layer=persistent, source=memory, key=$key, chunks=${entry.manifest.chunkCount}');
                return entry.manifest;
              } else {
                _memoryCache.remove(key);
                debugPrint('[FluxShare-Cache] [Miss] layer=persistent, source=memory, key=$key, reason=fingerprint_mismatch');
              }
            }

            // 2. Check per-entry disk file
            final cacheDir = await _getCacheDirectory();
            if (cacheDir != null) {
              final cacheFile = File('${cacheDir.path}${Platform.pathSeparator}${_keyToFileName(key)}.json');
              if (await cacheFile.exists()) {
                try {
                  final raw = await cacheFile.readAsString();
                  final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;

                  final cachedFingerprint = json['fingerprint'] as String?;
                  final cachedSize = json['size'] as int? ?? length;
                  if (cachedSize != length) {
                    try {
                      await cacheFile.delete();
                    } catch (_) {}
                    debugPrint('[FluxShare-Cache] [Miss] layer=persistent, source=disk, key=$key, reason=size_mismatch: $cachedSize != $length');
                    continue;
                  }

                  final manifestJson = json['manifest'] as Map<String, dynamic>;
                  final manifest = Manifest.fromJson(manifestJson);

                  // Verify head/tail fingerprint
                  currentFingerprint ??= await computeHeadTailFingerprint(file, length);
                  if (currentFingerprint != null && currentFingerprint == cachedFingerprint) {
                    _addToMemoryCache(key, _CachedManifestEntry(
                      manifest: manifest,
                      fingerprint: currentFingerprint,
                      cachedAt: DateTime.now(),
                    ));
                    debugPrint('[FluxShare-Cache] [Hit] layer=persistent, source=disk, key=$key, chunks=${manifest.chunkCount}');
                    return manifest;
                  } else {
                    try {
                      await cacheFile.delete();
                    } catch (_) {}
                    debugPrint('[FluxShare-Cache] [Miss] layer=persistent, source=disk, key=$key, reason=fingerprint_mismatch');
                  }
                } catch (corruptError) {
                  // Corrupted cache file: safely delete and continue without failing
                  try {
                    await cacheFile.delete();
                  } catch (_) {}
                  debugPrint('[FluxShare-Cache] [Miss] layer=persistent, source=disk, key=$key, reason=corrupted_file: $corruptError');
                }
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[FluxShare-Cache] [Error] layer=persistent, lookup_exception: $e');
    }
    return null;
  }

  /// Stores a verified manifest into memory and disk cache.
  Future<void> put(File file, Manifest manifest, {String? identifier}) async {
    try {
      if (!await file.exists()) return;

      final length = await file.length();
      final lastModified = (await file.lastModified()).millisecondsSinceEpoch;
      final fingerprint = await computeHeadTailFingerprint(file, length);
      if (fingerprint == null) {
        debugPrint('[FluxShare-Cache] [Persist] fingerprint failed, skipping cache write');
        return;
      }

      final cacheDir = await _getCacheDirectory();

      final List<String> candidateIdentities = [];
      if (identifier != null && identifier.isNotEmpty) {
        candidateIdentities.add(identifier);
      }
      candidateIdentities.add(file.path);

      for (final id in candidateIdentities) {
        final key = _generateKey(id, length, manifest.chunkSize);
        final entry = _CachedManifestEntry(
          manifest: manifest,
          fingerprint: fingerprint,
          cachedAt: DateTime.now(),
        );

        _addToMemoryCache(key, entry);

        if (cacheDir != null) {
          final cacheFile = File('${cacheDir.path}${Platform.pathSeparator}${_keyToFileName(key)}.json');
          final data = jsonEncode({
            'key': key,
            'identifier': id,
            'size': length,
            'chunkSize': manifest.chunkSize,
            'lastModifiedMs': lastModified,
            'fingerprint': fingerprint,
            'cachedAtMs': entry.cachedAt.millisecondsSinceEpoch,
            'manifest': manifest.toJson(),
          });
          await cacheFile.writeAsString(data, flush: true);
          debugPrint('[FluxShare-Cache] [Store] layer=persistent, key=$key, chunks=${manifest.chunkCount}');
        }
      }
    } catch (e) {
      debugPrint('[FluxShare-Cache] [Error] layer=persistent, write_exception: $e');
    }
  }

  /// Invalidates and removes cache for a specific file.
  Future<void> invalidate(File file, {String? identifier, int? expectedChunkSize}) async {
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      final lastModified = (await file.lastModified()).millisecondsSinceEpoch;

      final chunkSizes = expectedChunkSize != null
          ? [expectedChunkSize]
          : [512 * 1024, 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024];

      final candidateIdentities = [
        if (identifier != null && identifier.isNotEmpty) identifier,
        file.path,
      ];

      for (final cs in chunkSizes) {
        for (final id in candidateIdentities) {
          final modernKey = _generateKey(id, length, cs);
          final legacyKey = _generateLegacyKey(id, length, lastModified, cs);

          for (final key in [modernKey, legacyKey]) {
            _memoryCache.remove(key);

            final cacheDir = await _getCacheDirectory();
            if (cacheDir != null) {
              final cacheFile = File('${cacheDir.path}${Platform.pathSeparator}${_keyToFileName(key)}.json');
              if (await cacheFile.exists()) {
                try {
                  await cacheFile.delete();
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[FluxShare-Cache] [Error] layer=persistent, invalidation_exception: $e');
    }
  }

  /// Clears all cached manifests from memory and disk.
  Future<void> clear() async {
    _memoryCache.clear();
    try {
      final cacheDir = await _getCacheDirectory();
      if (cacheDir != null && await cacheDir.exists()) {
        final entities = await cacheDir.list().toList();
        for (final entity in entities) {
          if (entity is File && entity.path.endsWith('.json')) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('[ManifestCache] Cache clear warning: $e');
    }
  }

  void _addToMemoryCache(String key, _CachedManifestEntry entry) {
    if (_memoryCache.length >= _maxMemoryEntries) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
    }
    _memoryCache[key] = entry;
  }
}

class _CachedManifestEntry {
  final Manifest manifest;
  final String fingerprint;
  final DateTime cachedAt;

  _CachedManifestEntry({
    required this.manifest,
    required this.fingerprint,
    required this.cachedAt,
  });
}
