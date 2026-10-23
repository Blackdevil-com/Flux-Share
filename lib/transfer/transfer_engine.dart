import 'dart:async';
import 'dart:io';
import '../file/chunk_manager.dart';
import '../file/file_hasher.dart';
import '../metrics/metrics_collector.dart';
import '../models/chunk.dart';
import '../models/manifest.dart';
import '../models/peer.dart';
import '../models/transfer.dart';
import '../network/local_server.dart';
import '../network/websocket_service.dart';
import '../scheduler/chunk_scheduler.dart';
import '../scheduler/round_robin_scheduler.dart';
import 'chunk_downloader.dart';
import 'peer_concurrency_manager.dart';
import 'reservation_manager.dart';
import 'transfer_worker.dart';

class TransferProgressEvent {
  final String transferId;
  final TransferStatus status;
  final double progressPercent;
  final int bytesTransferred;
  final int totalBytes;
  final double speedMbPerSec;
  final int remainingSeconds;
  final String? errorMessage;

  const TransferProgressEvent({
    required this.transferId,
    required this.status,
    required this.progressPercent,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speedMbPerSec,
    required this.remainingSeconds,
    this.errorMessage,
  });
}

/// Core cooperative transfer orchestration engine.
/// Features AIMD transport congestion control, persistent HTTP connection reuse,
/// streaming zero-RAM disk I/O, background isolate hashing, and research metrics.
class TransferEngine {
  final Manifest manifest;
  final File destinationFile;
  final List<PeerInfo> swarmPeers;
  final LocalServer localServer;
  final WebSocketService? webSocketService;
  final int concurrentWorkers;
  final ChunkScheduler scheduler;
  final String localPeerId;
  final String coordinatorPeerId;

  late final ReservationManager _reservationManager;
  late final ChunkWriterSession _writerSession;
  late final ChunkDownloader _sharedDownloader;
  late final PeerConcurrencyManager _concurrencyManager;
  final List<TransferWorker> _workers = [];

  final Set<int> _verifiedChunks = {};
  final Map<int, ChunkState> _chunkStates = {};
  final MetricsCollector _metricsCollector = MetricsCollector();

  TransferStatus _status = TransferStatus.starting;
  int _bytesTransferred = 0;
  final Stopwatch _transferStopwatch = Stopwatch();
  Completer<bool>? _completionCompleter;
  Timer? _progressTimer;

  final _progressController = StreamController<TransferProgressEvent>.broadcast();

  TransferEngine({
    required this.manifest,
    required this.destinationFile,
    required this.swarmPeers,
    required this.localServer,
    this.webSocketService,
    required this.localPeerId,
    required this.coordinatorPeerId,
    this.concurrentWorkers = 5,
    ChunkScheduler? scheduler,
  }) : scheduler = scheduler ?? RoundRobinScheduler() {
    _reservationManager = ReservationManager();
    _writerSession = ChunkWriterSession(
      file: destinationFile,
      totalSize: manifest.fileSize,
    );
    _sharedDownloader = ChunkDownloader();
    _concurrencyManager = PeerConcurrencyManager();

    for (final c in manifest.chunks) {
      _chunkStates[c.chunkId] = ChunkState.missing;
    }
  }

  Stream<TransferProgressEvent> get progressStream => _progressController.stream;
  TransferStatus get status => _status;
  double get progressPercent => manifest.fileSize > 0
      ? (_bytesTransferred / manifest.fileSize) * 100.0
      : 0.0;

  /// Starts the cooperative parallel download.
  Future<bool> start() async {
    if (_status == TransferStatus.transferring) return true;

    _status = TransferStatus.starting;
    _emitProgress();

    _completionCompleter = Completer<bool>();
    _transferStopwatch.start();

    // Initialize metrics recording
    _metricsCollector.startTransfer(
      transferId: manifest.fileId,
      fileId: manifest.fileId,
      fileName: manifest.fileName,
      fileSize: manifest.fileSize,
      chunkCount: manifest.chunkCount,
      chunkSize: manifest.chunkSize,
      coordinatorPeerId: coordinatorPeerId,
      receiverCount: swarmPeers.length,
      schedulerMode: 'round-robin',
    );

    try {
      // 1. Open writer session & preallocate full size immediately
      await _writerSession.open();

      _status = TransferStatus.transferring;
      _emitProgress();

      // Periodic progress ticker
      _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _emitProgress();
      });

      // 2. Spawn concurrent workers sharing pooled HTTP client
      final workerCount = concurrentWorkers > 0 ? concurrentWorkers : 6;
      for (int i = 0; i < workerCount; i++) {
        final worker = TransferWorker(
          workerId: 'worker_$i',
          reservationManager: _reservationManager,
          writerSession: _writerSession,
          downloader: _sharedDownloader,
          getNextWork: _selectNextWork,
          onChunkSuccess: _handleChunkSuccess,
          onChunkFailure: _handleChunkFailure,
        );
        _workers.add(worker);
        worker.start();
      }

      return await _completionCompleter!.future;
    } catch (e) {
      _handleFatalError('Failed to start transfer: $e');
      return false;
    }
  }

  /// Selects next missing and unreserved chunk using the swappable ChunkScheduler
  /// filtered through AIMD transport capacity and cooldown constraints.
  ({ChunkMeta chunk, PeerInfo peer})? _selectNextWork(String workerId) {
    if (_status != TransferStatus.transferring) return null;

    final missingChunkIds = _chunkStates.entries
        .where((e) => e.value == ChunkState.missing)
        .map((e) => e.key)
        .toSet();

    if (missingChunkIds.isEmpty) return null;

    // Filter out chunks currently reserved by other workers
    final availableMissing = missingChunkIds
        .where((id) => !_reservationManager.isReserved(id))
        .toSet();

    if (availableMissing.isEmpty) return null;

    // Filter candidate peers through transport capacity and cooldown constraints
    final eligibleCandidates = _concurrencyManager.filterAvailableCandidates(swarmPeers);
    if (eligibleCandidates.isEmpty) {
      return null;
    }

    // Use swappable scheduler to pick the best peer candidate among available
    final selectedPeer = scheduler.selectSource(availableMissing, eligibleCandidates);
    if (selectedPeer == null) {
      return null;
    }

    // Pick first chunk available from this selected peer
    final targetChunkId = availableMissing.firstWhere(
      (id) => selectedPeer.availableChunks.contains(id) || selectedPeer.peerId == coordinatorPeerId,
      orElse: () => availableMissing.first,
    );

    final chunkMeta = manifest.chunks.firstWhere((c) => c.chunkId == targetChunkId);
    _chunkStates[targetChunkId] = ChunkState.requested;

    // Mark request in flight
    _concurrencyManager.markRequestStarted(selectedPeer.peerId);
    _metricsCollector.recordPeerConcurrency(
      selectedPeer.peerId,
      _concurrencyManager.getAllowedConcurrency(selectedPeer.peerId),
    );

    return (chunk: chunkMeta, peer: selectedPeer);
  }

  /// Handles verified chunk commit: Additive Increase and metrics recording.
  void _handleChunkSuccess(
    int chunkId,
    String sourcePeerId,
    int bytes,
    Duration? timeToFirstByte,
  ) {
    _chunkStates[chunkId] = ChunkState.completed;
    _verifiedChunks.add(chunkId);
    _bytesTransferred += bytes;

    // Transport AIMD: Additive Increase on success
    _concurrencyManager.markRequestSuccess(sourcePeerId);

    // Record research metrics
    _metricsCollector.recordChunkDelivered(
      sourcePeerId: sourcePeerId,
      receiverPeerId: localPeerId,
      bytes: bytes,
    );

    if (timeToFirstByte != null) {
      _metricsCollector.recordTimeToFirstByte(chunkId, timeToFirstByte.inMilliseconds);
    }

    _metricsCollector.recordPeerConcurrency(
      sourcePeerId,
      _concurrencyManager.getAllowedConcurrency(sourcePeerId),
    );

    // Make available immediately on local server for cooperative forwarding!
    localServer.setVerifiedChunks(_verifiedChunks);

    // Broadcast CHUNK_AVAILABLE via WebSocket to swarm
    try {
      webSocketService?.notifyChunkAvailable(chunkId);
    } catch (_) {}

    _emitProgress();

    // Check if all chunks have finished downloading
    if (_verifiedChunks.length == manifest.chunkCount) {
      _finalizeTransferGate();
    }
  }

  /// Handles chunk failure: Multiplicative Decrease, Cooldown, and immediate retry.
  void _handleChunkFailure(int chunkId, String sourcePeerId, String reason) {
    // Return to MISSING so another worker/peer can retry immediately
    _chunkStates[chunkId] = ChunkState.missing;

    // Transport AIMD: Multiplicative Decrease & cooldown increment
    _concurrencyManager.markRequestFailure(sourcePeerId);

    _metricsCollector.recordRetransmission();
    _metricsCollector.recordRetryEvent(
      chunkId: chunkId,
      failedPeerId: sourcePeerId,
      reason: reason,
    );
    _metricsCollector.recordPeerConcurrency(
      sourcePeerId,
      _concurrencyManager.getAllowedConcurrency(sourcePeerId),
    );

    _emitProgress();
  }

  /// 3-Tier Completion Verification Gate (Non-negotiable Integrity Rule).
  Future<void> _finalizeTransferGate() async {
    // 1. Stop workers and flush writer session
    for (final worker in _workers) {
      await worker.stop();
    }
    _workers.clear();
    await _writerSession.close();

    _progressTimer?.cancel();
    _transferStopwatch.stop();

    // TIER 1: Destination file must exist on disk
    if (!await destinationFile.exists()) {
      _handleFatalError('Integrity Failure (Tier 1): Destination file does not exist on disk.');
      return;
    }

    // TIER 2: Destination file size must match manifest exactly
    final actualSize = await destinationFile.length();
    if (actualSize != manifest.fileSize) {
      _handleFatalError(
        'Integrity Failure (Tier 2): File size mismatch. Expected ${manifest.fileSize} bytes, found $actualSize bytes.',
      );
      return;
    }

    // TIER 3: Whole-file SHA-256 must match manifest exactly (computed off main isolate)
    final wholeFileHash = await FileHasher.computeFileSha256(destinationFile);
    if (wholeFileHash.toLowerCase() != manifest.fileSha256.toLowerCase()) {
      _handleFatalError(
        'Integrity Failure (Tier 3): Whole-file SHA-256 hash mismatch. Expected ${manifest.fileSha256}, got $wholeFileHash.',
      );
      return;
    }

    // All 3 tiers verified successfully!
    _status = TransferStatus.completed;
    await _metricsCollector.finalizeTransfer();

    try {
      webSocketService?.notifyTransferCompleted();
    } catch (_) {}

    _emitProgress();
    if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
      _completionCompleter!.complete(true);
    }
  }

  void _handleFatalError(String errorMsg) {
    _status = TransferStatus.failed;
    _progressTimer?.cancel();
    _transferStopwatch.stop();
    _writerSession.close();

    for (final worker in _workers) {
      worker.stop();
    }
    _workers.clear();

    _emitProgress(errorMessage: errorMsg);
    if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
      _completionCompleter!.complete(false);
    }
  }

  void pause() {
    if (_status != TransferStatus.transferring) return;
    _status = TransferStatus.paused;
    for (final worker in _workers) {
      worker.pause();
    }
    try {
      webSocketService?.notifyTransferPaused();
    } catch (_) {}
    _emitProgress();
  }

  void resume() {
    if (_status != TransferStatus.paused) return;
    _status = TransferStatus.transferring;
    for (final worker in _workers) {
      worker.resume();
    }
    try {
      webSocketService?.notifyTransferResumed();
    } catch (_) {}
    _emitProgress();
  }

  Future<void> cancel() async {
    _status = TransferStatus.cancelled;
    _progressTimer?.cancel();
    _transferStopwatch.stop();

    for (final worker in _workers) {
      await worker.stop();
    }
    _workers.clear();
    _reservationManager.clear();
    await _writerSession.close();
    _sharedDownloader.close();

    try {
      webSocketService?.notifyTransferCancelled();
    } catch (_) {}

    _emitProgress();
    if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
      _completionCompleter!.complete(false);
    }
  }

  void _emitProgress({String? errorMessage}) {
    final elapsedSec = _transferStopwatch.elapsedMicroseconds / 1000000.0;
    final speed = elapsedSec > 0 ? (_bytesTransferred / (1024 * 1024)) / elapsedSec : 0.0;
    final remainingBytes = manifest.fileSize - _bytesTransferred;
    final remainingSec = (speed > 0 && remainingBytes > 0)
        ? (remainingBytes / (speed * 1024 * 1024)).ceil()
        : 0;

    final event = TransferProgressEvent(
      transferId: manifest.fileId,
      status: _status,
      progressPercent: progressPercent,
      bytesTransferred: _bytesTransferred,
      totalBytes: manifest.fileSize,
      speedMbPerSec: speed,
      remainingSeconds: remainingSec,
      errorMessage: errorMessage,
    );

    _progressController.add(event);
  }

  /// Applies dynamic optimization settings recommended by AI and approved by user.
  void applyOptimizationSettings({int? maxWorkers}) {
    if (maxWorkers != null && maxWorkers > 0 && _status == TransferStatus.transferring) {
      if (maxWorkers < _workers.length) {
        while (_workers.length > maxWorkers) {
          final removed = _workers.removeLast();
          removed.stop();
        }
      } else if (maxWorkers > _workers.length) {
        final startIdx = _workers.length;
        for (int i = startIdx; i < maxWorkers; i++) {
          final worker = TransferWorker(
            workerId: 'worker_$i',
            reservationManager: _reservationManager,
            writerSession: _writerSession,
            downloader: _sharedDownloader,
            getNextWork: _selectNextWork,
            onChunkSuccess: _handleChunkSuccess,
            onChunkFailure: _handleChunkFailure,
          );
          _workers.add(worker);
          worker.start();
        }
      }
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    _progressController.close();
    _writerSession.close();
    _sharedDownloader.close();
    for (final worker in _workers) {
      worker.stop();
    }
  }
}
