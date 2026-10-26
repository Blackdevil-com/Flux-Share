import '../models/transfer_failure_reason.dart';
import 'dart:async';
import '../models/chunk.dart';
import '../models/peer.dart';
import '../file/chunk_manager.dart';
import 'chunk_downloader.dart';
import 'reservation_manager.dart';

typedef OnChunkSuccess = void Function(
  int chunkId,
  String sourcePeerId,
  int bytes,
  Duration chunkDuration,
  Duration? timeToFirstByte,
);
typedef OnChunkFailure = void Function(
  int chunkId,
  String sourcePeerId,
  String reason, {
  TransferFailureReason? failureReason,
});
typedef SelectWorkCallback = ({ChunkMeta chunk, PeerInfo peer})? Function(String workerId);

/// A parallel transfer worker that requests, streams, verifies, and commits chunks.
/// Reuses persistent HTTP connection pooling, safely renews active reservations,
/// and guarantees release of chunk reservations on every terminal path.
class TransferWorker {
  final String workerId;
  final String? fileId;
  final ReservationManager reservationManager;
  final ChunkWriterSession writerSession;
  final ChunkDownloader downloader;
  final SelectWorkCallback getNextWork;
  final OnChunkSuccess onChunkSuccess;
  final OnChunkFailure onChunkFailure;

  bool _isRunning = false;
  bool _isPaused = false;
  Completer<void>? _workerLoopCompleter;

  TransferWorker({
    required this.workerId,
    this.fileId,
    required this.reservationManager,
    required this.writerSession,
    required this.downloader,
    required this.getNextWork,
    required this.onChunkSuccess,
    required this.onChunkFailure,
  });

  bool get isRunning => _isRunning;

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _isPaused = false;
    _workerLoopCompleter = Completer<void>();
    _runLoop();
  }

  void pause() {
    _isPaused = true;
  }

  void resume() {
    if (_isPaused) {
      _isPaused = false;
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    reservationManager.releaseAll(workerId);
    if (_workerLoopCompleter != null && !_workerLoopCompleter!.isCompleted) {
      await _workerLoopCompleter!.future;
    }
  }

  Future<void> _runLoop() async {
    while (_isRunning) {
      if (_isPaused) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final work = getNextWork(workerId);
      if (work == null) {
        // No work currently ready or available
        await Future.delayed(const Duration(milliseconds: 40));
        continue;
      }

      final chunk = work.chunk;
      final peer = work.peer;

      // Start periodic reservation renewal timer to prevent expiry during long-running downloads
      Timer? renewalTimer;
      renewalTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!_isRunning || _isPaused) {
          renewalTimer?.cancel();
          return;
        }
        reservationManager.renew(chunk.chunkId, workerId);
      });

      ChunkDownloadResult? result;
      try {
        result = await downloader.downloadChunk(
          peer: peer,
          chunkMeta: chunk,
          writerSession: writerSession,
          fileId: fileId,
          allowLegacyFallback: true,
        );
      } catch (e) {
        result = ChunkDownloadResult(
          chunkId: chunk.chunkId,
          success: false,
          peerId: peer.peerId,
          bytes: 0,
          duration: Duration.zero,
          errorMessage: e.toString(),
        );
      } finally {
        renewalTimer.cancel();
        reservationManager.release(chunk.chunkId);
      }

      if (!_isRunning) break;

      if (result.success) {
        onChunkSuccess(
          chunk.chunkId,
          peer.peerId,
          result.bytes,
          result.duration,
          result.timeToFirstByte,
        );
      } else {
        onChunkFailure(
          chunk.chunkId,
          peer.peerId,
          result.errorMessage ?? 'Download error',
          failureReason: result.failureReason,
        );
      }
    }

    if (_workerLoopCompleter != null && !_workerLoopCompleter!.isCompleted) {
      _workerLoopCompleter!.complete();
    }
  }
}
