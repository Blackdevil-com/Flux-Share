import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../file/chunk_manager.dart';
import '../models/chunk.dart';
import '../models/peer.dart';
import '../models/transfer_failure_reason.dart';

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
  final TransferFailureReason? failureReason;
  final int? statusCode;

  const ChunkDownloadResult({
    required this.chunkId,
    required this.success,
    required this.peerId,
    required this.bytes,
    required this.duration,
    this.timeToFirstByte,
    this.errorMessage,
    this.failureReason,
    this.statusCode,
  });
}

/// High-throughput streaming chunk downloader with persistent connection pooling,
/// in-flight SHA-256 verification, and atomic disk writes for verified chunks only.
class ChunkDownloader {
  final HttpClient _httpClient;

  /// Creates a downloader reusing a pooled HttpClient or initializing a persistent one.
  ChunkDownloader({HttpClient? httpClient})
      : _httpClient = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 5)
              ..idleTimeout = const Duration(seconds: 30)
              ..maxConnectionsPerHost = 10);

  /// Downloads a chunk streaming bytes into a memory buffer and hashing in-flight.
  /// Verifies byte count and SHA-256 BEFORE writing to disk to prevent partial corruption.
  Future<ChunkDownloadResult> downloadChunk({
    required PeerInfo peer,
    required ChunkMeta chunkMeta,
    required ChunkWriterSession writerSession,
    String? fileId,
    String? localPeerId,
    bool allowLegacyFallback = false,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration headerTimeout = const Duration(seconds: 8),
    Duration bodyStreamIdleTimeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();
    final encodedFileId = fileId != null ? Uri.encodeComponent(fileId) : null;
    final primaryUrl = encodedFileId != null
        ? 'http://${peer.ip}:${peer.httpPort}/file/$encodedFileId/chunk/${chunkMeta.chunkId}'
        : 'http://${peer.ip}:${peer.httpPort}/chunk/${chunkMeta.chunkId}';

    Duration? timeToFirstByte;
    int bytesReceived = 0;
    final List<List<int>> chunkBuffers = [];

    // In-flight streaming hasher
    final digestSink = _DigestAccumulator();
    final inFlightHasher = sha256.startChunkedConversion(digestSink);

    try {
      HttpClientResponse response;
      final requestFuture = _httpClient.getUrl(Uri.parse(primaryUrl));
      final request = await requestFuture.timeout(
        connectTimeout,
        onTimeout: () => throw TimeoutException('Connection timed out connecting to ${peer.ip}'),
      );
      if (localPeerId != null && localPeerId.isNotEmpty) {
        request.headers.set('X-Peer-Id', localPeerId);
      }

      final responseFuture = request.close();
      response = await responseFuture.timeout(
        headerTimeout,
        onTimeout: () => throw TimeoutException('Peer ${peer.ip} failed to send response headers'),
      );

      // Multi-file endpoint 404: only fallback if explicitly allowed and not an isolated multi-file request
      if (response.statusCode == HttpStatus.notFound && fileId != null && allowLegacyFallback) {
        final fallbackUrl = 'http://${peer.ip}:${peer.httpPort}/chunk/${chunkMeta.chunkId}';
        final fallbackReq = await _httpClient.getUrl(Uri.parse(fallbackUrl)).timeout(
          connectTimeout,
          onTimeout: () => throw TimeoutException('Fallback connection timed out to ${peer.ip}'),
        );
        if (localPeerId != null && localPeerId.isNotEmpty) {
          fallbackReq.headers.set('X-Peer-Id', localPeerId);
        }
        response = await fallbackReq.close().timeout(
          headerTimeout,
          onTimeout: () => throw TimeoutException('Peer ${peer.ip} failed on fallback headers'),
        );
      }

      if (response.statusCode != HttpStatus.ok) {
        stopwatch.stop();
        peer.recordFailure();
        String detail = '';
        try {
          final bodyBytes = await response.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
          detail = utf8.decode(bodyBytes, allowMalformed: true).trim();
        } catch (_) {}
        final reason = response.statusCode == HttpStatus.notFound
            ? TransferFailureReason.notFound
            : TransferFailureReason.httpError;
        final errorMsg = detail.isNotEmpty
            ? 'HTTP ${response.statusCode} from ${peer.peerId}: $detail'
            : 'HTTP ${response.statusCode} from ${peer.peerId}';
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: 0,
          duration: stopwatch.elapsed,
          statusCode: response.statusCode,
          failureReason: reason,
          errorMessage: errorMsg,
        );
      }

      // Stream incoming bytes into chunk buffer and in-flight hasher with idle timeout
      await for (final buffer in response.timeout(bodyStreamIdleTimeout)) {
        timeToFirstByte ??= stopwatch.elapsed;

        inFlightHasher.add(buffer);
        chunkBuffers.add(buffer);
        bytesReceived += buffer.length;
      }

      inFlightHasher.close();

      // 1. Verify byte count
      if (bytesReceived != chunkMeta.length) {
        stopwatch.stop();
        peer.recordFailure();
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: bytesReceived,
          duration: stopwatch.elapsed,
          timeToFirstByte: timeToFirstByte,
          failureReason: TransferFailureReason.lengthMismatch,
          errorMessage: 'Length mismatch: expected ${chunkMeta.length}, got $bytesReceived',
        );
      }

      // 2. Verify SHA-256 integrity from streaming digest
      final computedSha256 = digestSink.value?.toString() ?? '';
      if (computedSha256.toLowerCase() != chunkMeta.sha256.toLowerCase()) {
        stopwatch.stop();
        peer.recordFailure();
        return ChunkDownloadResult(
          chunkId: chunkMeta.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: bytesReceived,
          duration: stopwatch.elapsed,
          timeToFirstByte: timeToFirstByte,
          failureReason: TransferFailureReason.sha256Mismatch,
          errorMessage: 'Chunk SHA-256 mismatch: expected ${chunkMeta.sha256}, got $computedSha256',
        );
      }

      // 3. ATOMIC WRITE: Write only verified chunk to disk in a single pass
      try {
        await writerSession.writeVerifiedChunk(chunkMeta.offset, chunkBuffers);
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
          failureReason: TransferFailureReason.diskWriteFailure,
          errorMessage: 'Disk write failed at offset ${chunkMeta.offset}: $e',
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
        statusCode: HttpStatus.ok,
      );
    } on SocketException catch (e) {
      stopwatch.stop();
      peer.recordFailure();
      return ChunkDownloadResult(
        chunkId: chunkMeta.chunkId,
        success: false,
        peerId: peer.peerId,
        bytes: bytesReceived,
        duration: stopwatch.elapsed,
        timeToFirstByte: timeToFirstByte,
        failureReason: TransferFailureReason.connectionRefused,
        errorMessage: 'Connection refused or peer unreachable: ${e.message}',
      );
    } on TimeoutException catch (e) {
      stopwatch.stop();
      peer.recordFailure();
      final reason = e.message?.contains('headers') == true
          ? TransferFailureReason.timeoutHeaders
          : (e.message?.contains('Connection') == true
              ? TransferFailureReason.timeoutConnection
              : TransferFailureReason.timeoutBody);
      return ChunkDownloadResult(
        chunkId: chunkMeta.chunkId,
        success: false,
        peerId: peer.peerId,
        bytes: bytesReceived,
        duration: stopwatch.elapsed,
        timeToFirstByte: timeToFirstByte,
        failureReason: reason,
        errorMessage: e.message ?? 'Timeout during chunk download',
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
        failureReason: TransferFailureReason.unknown,
        errorMessage: e.toString(),
      );
    }
  }

  void close() {
    _httpClient.close(force: true);
  }
}
