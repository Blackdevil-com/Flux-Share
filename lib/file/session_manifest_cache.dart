import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/manifest.dart';
import 'manifest_cache.dart';

/// In-memory cache of validated, completed manifests scoped to an active Send Files session.
///
/// Preserves completed manifests when files are removed and re-selected during the
/// current send session, avoiding redundant multi-hundred-megabyte disk I/O and SHA-256 hashing.
///
/// Lifecycle:
/// - Initialized when `SendFileScreen` is created.
/// - Preserves entries across multi-file addition, deletion, and re-selection.
/// - Released when `SendFileScreen` is disposed (navigated away) or when the user
///   explicitly resets the send session.
/// - Removing an individual file preserves its session-cache entry for subsequent re-selection.
class SessionManifestCache {
  final Map<String, SessionCacheEntry> _entries = {};

  /// Generates a normalized session cache key based on stable file identity,
  /// file size, and effective chunk size. Never uses the display name alone.
  static String generateKey({
    required String identity,
    required int sizeBytes,
    required int chunkSize,
  }) {
    final normalizedId = identity.replaceAll('\\', '/');
    return '$normalizedId:$sizeBytes:$chunkSize';
  }

  /// Checks if the session cache contains a valid manifest for [file] and [identity].
  ///
  /// Validation:
  /// 1. An entry exists for the given key.
  /// 2. The file still exists on disk and its current length equals [sizeBytes].
  /// 3. The fast head & tail fingerprint matches the cached fingerprint (detects in-place modification).
  Future<Manifest?> get({
    required File file,
    required String identity,
    required int sizeBytes,
    required int chunkSize,
  }) async {
    final key = generateKey(identity: identity, sizeBytes: sizeBytes, chunkSize: chunkSize);
    debugPrint('[FluxShare-Cache] [Query] layer=session, identifier=$identity, size=$sizeBytes, chunkSize=$chunkSize');

    final entry = _entries[key];
    if (entry == null) {
      debugPrint('[FluxShare-Cache] [Miss] layer=session, identifier=$identity, reason=not_found');
      return null;
    }

    if (!await file.exists()) {
      _entries.remove(key);
      debugPrint('[FluxShare-Cache] [Miss] layer=session, identifier=$identity, reason=file_not_found_on_disk');
      return null;
    }

    final currentLength = await file.length();
    if (currentLength != sizeBytes) {
      _entries.remove(key);
      debugPrint('[FluxShare-Cache] [Miss] layer=session, identifier=$identity, reason=size_mismatch: $currentLength != $sizeBytes');
      return null;
    }

    // Fast head & tail fingerprint validation (up to 8 KB)
    final currentFingerprint = await ManifestCache.computeHeadTailFingerprint(file, currentLength);
    if (currentFingerprint == null || currentFingerprint != entry.fingerprint) {
      _entries.remove(key);
      debugPrint('[FluxShare-Cache] [Miss] layer=session, identifier=$identity, reason=fingerprint_mismatch');
      return null;
    }

    debugPrint('[FluxShare-Cache] [Hit] layer=session, identifier=$identity, chunks=${entry.manifest.chunkCount}');
    return entry.manifest;
  }

  /// Stores a completed and validated manifest in the session cache.
  void put({
    required String identity,
    required int sizeBytes,
    required int chunkSize,
    required String fingerprint,
    required Manifest manifest,
  }) {
    final key = generateKey(identity: identity, sizeBytes: sizeBytes, chunkSize: chunkSize);
    _entries[key] = SessionCacheEntry(
      identity: identity,
      sizeBytes: sizeBytes,
      chunkSize: chunkSize,
      fingerprint: fingerprint,
      manifest: manifest,
      cachedAt: DateTime.now(),
    );
    debugPrint('[FluxShare-Cache] [Store] layer=session, identifier=$identity, chunks=${manifest.chunkCount}');
  }

  /// Clears all session entries (invoked when send session ends).
  void clear() {
    final count = _entries.length;
    _entries.clear();
    debugPrint('[FluxShare-Cache] [Clear] layer=session, evictedCount=$count');
  }

  /// Number of active entries in the session cache.
  int get length => _entries.length;

  /// Whether the session cache contains an entry for [key].
  bool containsKey(String key) => _entries.containsKey(key);

  /// Removes an entry explicitly if invalidated.
  void removeKey(String key) => _entries.remove(key);
}

/// Metadata stored alongside a session-cached manifest.
class SessionCacheEntry {
  final String identity;
  final int sizeBytes;
  final int chunkSize;
  final String fingerprint;
  final Manifest manifest;
  final DateTime cachedAt;

  const SessionCacheEntry({
    required this.identity,
    required this.sizeBytes,
    required this.chunkSize,
    required this.fingerprint,
    required this.manifest,
    required this.cachedAt,
  });
}
