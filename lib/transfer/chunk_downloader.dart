import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../file/chunk_manager.dart';
import '../models/chunk.dart';
import '../models/peer.dart';

class _DigestAccumulator implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class ChunkDownloadResult {
  final int chunkId;
  final bool success;
  final String peerId;
  final int bytes;
  final Duration duration;
  final Duration? timeToFirstByte;
  final String? errorMessage;

  const ChunkDownloadResult({
    required this.chunkId,
    required this.success,
    required this.peerId,
    required this.bytes,
    required this.duration,
    this.timeToFirstByte,
    this.errorMessage,
  });
}

/// High-throughput streaming chunk downloader with persistent connection pooling,
/// in-flight SHA-256 calculation, and direct-to-disk incremental writes.
class ChunkDownloader {
  final HttpClient _httpClient;

  /// Creates a downloader reusing a pooled HttpClient or initializing a persistent one.
  ChunkDownloader({HttpClient? httpClient})
      : _httpClient = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 3)
              ..idleTimeout = const Duration(seconds: 30)
              ..maxConnectionsPerHost = 10);

  /// Downloads a chunk streaming bytes directly to disk and hashing in-flight.
  /// Never buffers the entire chunk in RAM. Supports multi-file endpoint with legacy fallback.
  Future<ChunkDownloadResult> downloadChunk({
    required PeerInfo peer,
    required ChunkMeta chunkMeta,
    required ChunkWriterSession writerSession,
    String? fileId,
    Duration requestTimeout = const Duration(seconds: 6),
  }) async {
    final stopwatch = Stopwatch()..start();
    final primaryUrl = fileId != null
        ? 'http://${peer.ip}:${peer.httpPort}/file/$fileId/chunk/${chunkMeta.chunkId}'
        : 'http://${peer.ip}:${peer.httpPort}/chunk/${chunkMeta.chunkId}';

    Duration? timeToFirstByte;
    int bytesReceived = 0;
    int currentOffset = chunkMeta.offset;

    // In-flight streaming hasher (zero whole-chunk RAM allocation)
    final digestSink = _DigestAccumulator();
    final inFlightHasher = sha256.startChunkedConversion(digestSink);

    try {
      HttpClientResponse response;
      final requestFuture = _httpClient.getUrl(Uri.parse(primaryUrl));
      final request = await requestFuture.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException('Connection timed out connecting to ${peer.ip}'),
      );

      final responseFuture = request.close();
      response = await responseFuture.timeout(
        const Duration(seconds: 4),
        onTimeout: () => throw TimeoutException('Peer ${peer.ip} failed to send response headers'),
      );

      // If multi-file endpoint returned 404, fallback to legacy /chunk/<id>
      if (response.statusCode == HttpStatus.notFound && fileId != null) {
        final fallbackUrl = 'http://${peer.ip}:${peer.httpPort}/chunk/${chunkMeta.chunkId}';
        final fallbackReq = await _httpClient.getUrl(Uri.parse(fallbackUrl)).timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException('Fallback connection timed out to ${peer.ip}'),
        );
        response = await fallbackReq.close().timeout(
          const Duration(seconds: 4),
          onTimeout: () => throw TimeoutException('Peer ${peer.ip} failed on fallback headers'),
        );
      }

      if (response.statusCode != HttpStatus.ok) {
        stopwatch.stop();
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: 0,
          duration: stopwatch.elapsed,
          errorMessage: 'HTTP ${response.statusCode} from ${peer.peerId}',
        );
      }

      // Stream incoming bytes directly to disk and in-flight hasher
      await for (final buffer in response.timeout(requestTimeout)) {
        timeToFirstByte ??= stopwatch.elapsed;

        inFlightHasher.add(buffer);
        bytesReceived += buffer.length;

        // Write incremental buffer to disk sequentially
        await writerSession.writeChunk(currentOffset, buffer);
        currentOffset += buffer.length;
      }

      inFlightHasher.close();

      // 1. Verify byte count
      if (bytesReceived != chunkMeta.length) {
        stopwatch.stop();
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: bytesReceived,
          duration: stopwatch.elapsed,
          timeToFirstByte: timeToFirstByte,
          errorMessage: 'Length mismatch: expected ${chunkMeta.length}, got $bytesReceived',
        );
      }

      // 2. Verify SHA-256 integrity from streaming digest
      final computedSha256 = digestSink.value?.toString() ?? '';
      if (computedSha256.toLowerCase() != chunkMeta.sha256.toLowerCase()) {
        stopwatch.stop();
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: bytesReceived,
          duration: stopwatch.elapsed,
          timeToFirstByte: timeToFirstByte,
          errorMessage: 'Chunk SHA-256 mismatch: expected ${chunkMeta.sha256}, got $computedSha256',
        );
      }

      stopwatch.stop();

      // Update peer metrics
      final seconds = stopwatch.elapsedMicroseconds / 1000000.0;
      final speedMbPerSec = seconds > 0 ? (bytesReceived / (1024 * 1024)) / seconds : 0.0;
      peer.updateThroughput(speedMbPerSec);
      peer.recordSuccess();

      return ChunkDownloadResult(
        chunkId: chunkMeta.chunkId,
        success: true,
        peerId: peer.peerId,
        bytes: bytesReceived,
        duration: stopwatch.elapsed,
        timeToFirstByte: timeToFirstByte,
      );
    } catch (e) {
      stopwatch.stop();
      peer.recordFailure();
      return ChunkDownloadResult(
        chunkId: chunkMeta.chunkId,
        success: false,
        peerId: peer.peerId,
        bytes: bytesReceived,
        duration: stopwatch.elapsed,
        timeToFirstByte: timeToFirstByte,
        errorMessage: e.toString(),
      );
    }
  }

  void close() {
    _httpClient.close(force: true);
  }
}
