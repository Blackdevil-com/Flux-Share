import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/chunk.dart';
import '../models/manifest.dart';

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

/// HTTP Client for manifest and chunk downloads.
class P2PHttpClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// Downloads manifest from peer with retries and detailed error reporting.
  Future<ManifestFetchResult> downloadManifest(
    String peerIp,
    int peerPort, {
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    final url = 'http://$peerIp:$peerPort/manifest';
    ManifestFetchResult? lastResult;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final request = await _client.getUrl(Uri.parse(url));
        final response = await request.close();

        if (response.statusCode == HttpStatus.ok) {
          final body = await response.transform(utf8.decoder).join();
          final jsonMap = jsonDecode(body) as Map<String, dynamic>;
          return ManifestFetchSuccess(Manifest.fromJson(jsonMap));
        } else {
          final errorBody = await response.transform(utf8.decoder).join();
          lastResult = ManifestFetchError(
            statusCode: response.statusCode,
            message: errorBody.isNotEmpty ? errorBody : 'HTTP ${response.statusCode}',
            url: url,
          );
        }
      } catch (e) {
        lastResult = ManifestFetchError(
          statusCode: 0,
          message: e.toString(),
          url: url,
        );
      }

      if (attempt < maxRetries) {
        await Future.delayed(retryDelay);
      }
    }

    return lastResult ??
        ManifestFetchError(statusCode: 0, message: 'Failed to download manifest', url: url);
  }

  /// Downloads a chunk and writes it directly to [destFile] at chunk offset.
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

      final List<int> bytes = [];
      await for (final data in response) {
        bytes.addAll(data);
      }

      if (bytes.length != chunk.length) {
        return false;
      }

      final raf = await destFile.open(mode: FileMode.append);
      await raf.setPosition(chunk.offset);
      await raf.writeFrom(bytes);
      await raf.flush();
      await raf.close();

      return true;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _client.close(force: true);
  }
}
