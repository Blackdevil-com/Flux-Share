import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../models/batch_manifest.dart';
import '../models/chunk.dart';
import '../models/manifest.dart';

class _DigestAccumulator implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

sealed class HealthCheckResult {}

class HealthCheckSuccess extends HealthCheckResult {
  final String peerId;
  final String deviceName;
  final String platform;
  final String version;
  HealthCheckSuccess({
    required this.peerId,
    required this.deviceName,
    required this.platform,
    required this.version,
  });
}

class HealthCheckFailure extends HealthCheckResult {
  final int statusCode;
  final String message;
  final String url;
  HealthCheckFailure({required this.statusCode, required this.message, required this.url});
}

class HealthCheckUnreachable extends HealthCheckResult {
  final String message;
  final String url;
  final Object? error;
  HealthCheckUnreachable({required this.message, required this.url, this.error});
}

sealed class ManifestFetchResult {}

class ManifestFetchSuccess extends ManifestFetchResult {
  final Manifest manifest;
  ManifestFetchSuccess(this.manifest);
}

class ManifestFetchError extends ManifestFetchResult {
  final int statusCode;
  final String message;
  final String url;
  ManifestFetchError({required this.statusCode, required this.message, required this.url});
}

sealed class BatchManifestFetchResult {}

class BatchManifestFetchSuccess extends BatchManifestFetchResult {
  final BatchManifest batchManifest;
  BatchManifestFetchSuccess(this.batchManifest);
}

class BatchManifestFetchError extends BatchManifestFetchResult {
  final int statusCode;
  final String message;
  final String url;
  BatchManifestFetchError({required this.statusCode, required this.message, required this.url});
}

/// HTTP Client for health checks, manifest retrieval, and chunk downloads.
class P2PHttpClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 10;

  /// Performs bounded HTTP GET /health check to verify the host is reachable and running FluxShare.
  Future<HealthCheckResult> checkHealth(
    String peerIp,
    int peerPort, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final url = 'http://$peerIp:$peerPort/health';
    try {
      debugPrint('[FluxShare-Network] [HealthCheck] Pinging $url (timeout: ${timeout.inSeconds}s)');
      final request = await _client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);

      if (response.statusCode == HttpStatus.ok) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        debugPrint(
            '[FluxShare-Network] [HealthCheck] Success from $url: peerId=${json['peerId']}, device=${json['deviceName']}');
        return HealthCheckSuccess(
          peerId: json['peerId'] as String? ?? '',
          deviceName: json['deviceName'] as String? ?? 'FluxShare Device',
          platform: json['platform'] as String? ?? 'unknown',
          version: json['version'] as String? ?? '1.0.0',
        );
      } else {
        final body = await response.transform(utf8.decoder).join();
        debugPrint('[FluxShare-Network] [HealthCheck] Failed with HTTP ${response.statusCode} from $url');
        return HealthCheckFailure(
          statusCode: response.statusCode,
          message: body.isNotEmpty ? body : 'HTTP ${response.statusCode}',
          url: url,
        );
      }
    } catch (e) {
      debugPrint('[FluxShare-Network] [HealthCheck] Host unreachable at $url: $e');
      return HealthCheckUnreachable(
        message: 'Could not connect to host at $peerIp:$peerPort: $e',
        url: url,
        error: e,
      );
    }
  }

  /// Downloads manifest from peer with retries and detailed error reporting.
  Future<ManifestFetchResult> downloadManifest(
    String peerIp,
    int peerPort, {
    String? fileId,
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    final encodedFileId = fileId != null ? Uri.encodeComponent(fileId) : null;
    final path = encodedFileId != null ? '/file/$encodedFileId/manifest' : '/manifest';
    final url = 'http://$peerIp:$peerPort$path';
    ManifestFetchResult? lastResult;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        debugPrint('[FluxShare-Network] [ManifestFetch] GET $url (attempt $attempt/$maxRetries)');
        final request = await _client.getUrl(Uri.parse(url));
        final response = await request.close();

        if (response.statusCode == HttpStatus.ok) {
          final body = await response.transform(utf8.decoder).join();
          final jsonMap = jsonDecode(body) as Map<String, dynamic>;
          debugPrint('[FluxShare-Network] [ManifestFetch] Success from $url: ${jsonMap['fileName']} (${jsonMap['fileSize']} bytes)');
          return ManifestFetchSuccess(Manifest.fromJson(jsonMap));
        } else {
          final errorBody = await response.transform(utf8.decoder).join();
          lastResult = ManifestFetchError(
            statusCode: response.statusCode,
            message: errorBody.isNotEmpty ? errorBody : 'HTTP ${response.statusCode}',
            url: url,
          );
          debugPrint('[FluxShare-Network] [ManifestFetch] HTTP ${response.statusCode} from $url: $errorBody');
        }
      } catch (e) {
        lastResult = ManifestFetchError(
          statusCode: 0,
          message: e.toString(),
          url: url,
        );
        debugPrint('[FluxShare-Network] [ManifestFetch] Error from $url: $e');
      }

      if (attempt < maxRetries) {
        await Future.delayed(retryDelay);
      }
    }

    return lastResult ??
        ManifestFetchError(statusCode: 0, message: 'Failed to download manifest', url: url);
  }

  /// Downloads batch manifest containing multiple files from peer with fallback to single manifest.
  Future<BatchManifestFetchResult> downloadBatchManifest(
    String peerIp,
    int peerPort, {
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    final batchUrl = 'http://$peerIp:$peerPort/manifests';
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        debugPrint('[FluxShare-Network] [BatchManifestFetch] GET $batchUrl (attempt $attempt/$maxRetries)');
        final request = await _client.getUrl(Uri.parse(batchUrl));
        final response = await request.close();

        if (response.statusCode == HttpStatus.ok) {
          final body = await response.transform(utf8.decoder).join();
          final jsonMap = jsonDecode(body) as Map<String, dynamic>;
          final batch = BatchManifest.fromJson(jsonMap);
          debugPrint(
              '[FluxShare-Network] [BatchManifestFetch] Success: ${batch.totalFiles} files, ${batch.totalBytes} bytes');
          return BatchManifestFetchSuccess(batch);
        } else {
          debugPrint('[FluxShare-Network] [BatchManifestFetch] HTTP ${response.statusCode} from $batchUrl');
        }
      } catch (e) {
        debugPrint('[FluxShare-Network] [BatchManifestFetch] Error on attempt $attempt: $e');
      }

      if (attempt < maxRetries) {
        await Future.delayed(retryDelay);
      }
    }

    // Fallback to single manifest for legacy single-file hosts
    debugPrint('[FluxShare-Network] [BatchManifestFetch] Falling back to single /manifest endpoint');
    final singleResult = await downloadManifest(peerIp, peerPort, maxRetries: 2);
    if (singleResult is ManifestFetchSuccess) {
      return BatchManifestFetchSuccess(BatchManifest.fromSingleManifest(singleResult.manifest));
    } else if (singleResult is ManifestFetchError) {
      return BatchManifestFetchError(
        statusCode: singleResult.statusCode,
        message: singleResult.message,
        url: singleResult.url,
      );
    }

    return BatchManifestFetchError(
      statusCode: 0,
      message: 'Failed to download batch manifest',
      url: batchUrl,
    );
  }

  /// Downloads a chunk streaming bytes directly to [destFile] with incremental SHA-256 verification.
  Future<bool> downloadChunk(
    String peerIp,
    int peerPort,
    ChunkMeta chunk,
    File destFile,
  ) async {
    final url = 'http://$peerIp:$peerPort/chunk/${chunk.chunkId}';
    try {
      final request = await _client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        return false;
      }

      final digestSink = _DigestAccumulator();
      final inFlightHasher = sha256.startChunkedConversion(digestSink);

      final parent = destFile.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }

      final raf = await destFile.open(mode: FileMode.write);
      try {
        await raf.setPosition(chunk.offset);
        int bytesReceived = 0;
        await for (final data in response) {
          inFlightHasher.add(data);
          bytesReceived += data.length;
          await raf.writeFrom(data);
        }
        inFlightHasher.close();
        await raf.flush();

        if (bytesReceived != chunk.length) {
          return false;
        }

        final computedSha = digestSink.value?.toString() ?? '';
        if (computedSha.toLowerCase() != chunk.sha256.toLowerCase()) {
          return false;
        }

        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  void close() {
    _client.close(force: true);
  }
}
