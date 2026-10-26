import '../models/transfer_failure_reason.dart';
import '../services/storage_diagnostics_service.dart';
import '../services/storage_path_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../file/chunk_manager.dart';
import '../file/chunk_persistence_manager.dart';
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
import 'transfer_metrics_calculator.dart';
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
  final TransferFailureReason? failureReason;
  final bool isPreviewReady;

  const TransferProgressEvent({
    required this.transferId,
    required this.status,
    required this.progressPercent,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speedMbPerSec,
    required this.remainingSeconds,
    this.errorMessage,
    this.failureReason,
    this.isPreviewReady = false,
  });
}

/// Core cooperative transfer orchestration engine.
/// Features AIMD transport congestion control, persistent HTTP connection reuse,
/// streaming zero-RAM disk I/O, background isolate hashing, and swappable schedulers.
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
  final String networkMode;

  late final ReservationManager _reservationManager;
  late final ChunkWriterSession _writerSession;
  late final ChunkDownloader _sharedDownloader;
  late final PeerConcurrencyManager _concurrencyManager;
  final List<TransferWorker> _workers = [];

  final Set<int> _verifiedChunks = {};
  final Map<int, ChunkState> _chunkStates = {};
  final Map<int, int> _chunkFailureCounts = {};
  final MetricsCollector _metricsCollector = MetricsCollector();
  final TransferMetricsCalculator _metricsCalculator = TransferMetricsCalculator();
  final Map<String, int> _peerChunkContributions = {};

  TransferStatus _status = TransferStatus.starting;
  int _bytesTransferred = 0;
  final Stopwatch _transferStopwatch = Stopwatch();
  Completer<bool>? _completionCompleter;
  Timer? _progressTimer;
  bool _isPreviewReady = false;
  TransferFailureReason? _lastFailureReason;
  String? _lastErrorMessage;

  TransferFailureReason? get lastFailureReason => _lastFailureReason;
  String? get lastErrorMessage => _lastErrorMessage;

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
    this.networkMode = 'wifi',
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
  bool get isPreviewReady => _isPreviewReady;
  ChunkScheduler get activeScheduler => scheduler;
  Map<String, int> get peerChunkContributions => Map.unmodifiable(_peerChunkContributions);

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

    // Map scheduler runtime type to human-readable mode
    final schedulerName = scheduler.runtimeType.toString()
        .replaceAll('Scheduler', '')
        .toLowerCase();

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
      schedulerMode: schedulerName,
      networkMode: networkMode,
    );

    try {
      // 0. Destination storage pre-check (Part A6)
      final availableSpace = await StorageDiagnosticsService().getAvailableStorageBytes(destinationFile.parent.path);
      if (availableSpace != null && availableSpace < manifest.fileSize + (20 * 1024 * 1024)) {
        _handleFatalError(
          'Not enough storage space on device. Required: ${manifest.formattedSize}',
          failureReason: TransferFailureReason.diskSpaceInsufficient,
        );
        return false;
      }

      // 1. Open writer session & preallocate full size immediately
      await _writerSession.open();

      // Check for resumable checkpoint
      final loadedCheckpoint = await ChunkPersistenceManager().loadCheckpoint(
        fileId: manifest.fileId,
        fileSha256: manifest.fileSha256,
      );
      if (loadedCheckpoint != null && loadedCheckpoint.isNotEmpty) {
        for (final cid in loadedCheckpoint) {
          if (cid >= 0 && cid < manifest.chunks.length && !_verifiedChunks.contains(cid)) {
            _chunkStates[cid] = ChunkState.completed;
            _verifiedChunks.add(cid);
            final c = manifest.chunks.firstWhere((x) => x.chunkId == cid);
            _bytesTransferred += c.length;
            localServer.markChunkAvailable(cid, fileId: manifest.fileId);
          }
        }
        _checkPreviewReadiness();
        if (_verifiedChunks.length == manifest.chunkCount) {
          unawaited(_finalizeTransferGate());
          return await _completionCompleter!.future;
        }
      }

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
          fileId: manifest.fileId,
          localPeerId: localPeerId,
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

    // Map candidate peers to their file-specific chunk availability
    final mappedCandidates = eligibleCandidates.map((p) {
      final fileChunks = p.getAvailableChunksForFile(manifest.fileId);
      if (fileChunks == p.availableChunks) return p;
      return p.copyWith(availableChunks: fileChunks);
    }).toList();

    // Use swappable scheduler to select chunk and peer
    final decision = scheduler.schedule(
      missingChunks: availableMissing,
      candidates: mappedCandidates,
      coordinatorPeerId: coordinatorPeerId,
    );
    if (decision == null) {
      return null;
    }

    final targetChunkId = decision.chunkId;
    // Map back to the original PeerInfo instance in eligibleCandidates
    final selectedPeer = eligibleCandidates.firstWhere(
      (p) => p.peerId == decision.peer.peerId,
      orElse: () => decision.peer,
    );

    // Atomically reserve the chunk for this worker to prevent race conditions
    final reserved = _reservationManager.tryReserve(targetChunkId, workerId);
    if (!reserved) {
      return null;
    }

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

  /// Handles verified chunk commit: Additive Increase, preview check, and metrics recording.
  void _handleChunkSuccess(
    int chunkId,
    String sourcePeerId,
    int bytes,
    Duration chunkDuration,
    Duration? timeToFirstByte,
  ) {
    if (_status == TransferStatus.cancelled) return;

    _chunkStates[chunkId] = ChunkState.completed;
    _verifiedChunks.add(chunkId);
    _bytesTransferred += bytes;

    // Transport AIMD: Additive Increase on success
    _concurrencyManager.markRequestSuccess(sourcePeerId);

    // Provide feedback to active scheduler with exact chunk transfer duration
    scheduler.recordTransferResult(
      peerId: sourcePeerId,
      chunkId: chunkId,
      success: true,
      bytesTransferred: bytes,
      duration: chunkDuration,
    );

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

    // Check preview-readiness
    _checkPreviewReadiness();

    // Record peer chunk contribution
    _peerChunkContributions[sourcePeerId] =
        (_peerChunkContributions[sourcePeerId] ?? 0) + 1;

    // Persist verified chunk checkpoint asynchronously
    unawaited(ChunkPersistenceManager().saveCheckpoint(
      fileId: manifest.fileId,
      fileName: manifest.fileName,
      fileSha256: manifest.fileSha256,
      fileSize: manifest.fileSize,
      totalChunks: manifest.chunkCount,
      verifiedChunks: _verifiedChunks,
    ));

    // Make available immediately on local server for cooperative forwarding!
    localServer.markChunkAvailable(chunkId, fileId: manifest.fileId);

    // Broadcast CHUNK_AVAILABLE via WebSocket to swarm
    try {
      webSocketService?.notifyChunkAvailable(chunkId, fileId: manifest.fileId);
    } catch (_) {}

    _emitProgress();

    // Check if all chunks have finished downloading
    if (_verifiedChunks.length == manifest.chunkCount) {
      _finalizeTransferGate();
    }
  }

  /// Handles chunk failure: Multiplicative Decrease, Cooldown, scheduler feedback, and immediate reassignment.
  void _handleChunkFailure(int chunkId, String sourcePeerId, String reason, {TransferFailureReason? failureReason}) {
    if (_status == TransferStatus.cancelled) return;

    _lastFailureReason = failureReason ?? TransferFailureReason.unknown;
    _lastErrorMessage = reason;

    final failures = (_chunkFailureCounts[chunkId] ?? 0) + 1;
    _chunkFailureCounts[chunkId] = failures;

    // Fail immediately on non-transient fatal errors (e.g., disk write failure, insufficient space)
    if (failureReason != null && !failureReason.isTransient) {
      _chunkStates[chunkId] = ChunkState.failed;
      _handleFatalError(reason, failureReason: failureReason);
      return;
    }

    if (failures >= 5) {
      _chunkStates[chunkId] = ChunkState.failed;
      _handleFatalError('Chunk $chunkId failed after 5 retry attempts: $reason', failureReason: TransferFailureReason.retriesExhausted);
      return;
    }

    // Return to MISSING so another worker/peer can retry immediately
    _chunkStates[chunkId] = ChunkState.missing;

    // Transport AIMD: Multiplicative Decrease & cooldown increment
    _concurrencyManager.markRequestFailure(sourcePeerId);

    // Provide feedback to active scheduler (e.g. UCB1 penalty)
    scheduler.recordTransferResult(
      peerId: sourcePeerId,
      chunkId: chunkId,
      success: false,
      bytesTransferred: 0,
      duration: Duration.zero,
      errorMessage: reason,
    );

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

  /// Explicit preview readiness detector for media files.
  /// Requires a contiguous verified prefix of at least 20% of the file chunks starting from chunk 0.
  void _checkPreviewReadiness() {
    if (_isPreviewReady) return;

    final ext = manifest.fileName.split('.').last.toLowerCase();
    final isStreamable = ['mp4', 'mkv', 'mov', 'webm', 'mp3', 'wav', 'm4a', 'pdf'].contains(ext);
    if (!isStreamable) return;

    // Prerequisite: Contiguous verified prefix of first 20% of chunks from offset 0
    final requiredCount = max(1, (manifest.chunkCount * 0.20).ceil());
    bool allRequiredVerified = true;
    for (int i = 0; i < requiredCount; i++) {
      if (!_verifiedChunks.contains(i)) {
        allRequiredVerified = false;
        break;
      }
    }

    if (allRequiredVerified) {
      _isPreviewReady = true;
      _metricsCollector.recordTimeToFirstPreviewReady(_transferStopwatch.elapsedMilliseconds);
    }
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
    await ChunkPersistenceManager().deleteCheckpoint(manifest.fileId);
    _status = TransferStatus.completed;
    await _metricsCollector.finalizeTransfer();

    try {
      await StoragePathService.scanFile(destinationFile.path);
    } catch (_) {}

    try {
      webSocketService?.notifyTransferCompleted(fileId: manifest.fileId);
    } catch (_) {}

    _emitProgress();
    if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
      _completionCompleter!.complete(true);
    }
  }

  void _handleFatalError(String errorMsg, {TransferFailureReason? failureReason}) {
    _status = TransferStatus.failed;
    _lastErrorMessage = errorMsg;
    _lastFailureReason = failureReason ?? TransferFailureReason.unknown;
    _progressTimer?.cancel();
    _transferStopwatch.stop();
    _writerSession.close();

    for (final worker in _workers) {
      worker.stop();
    }
    _workers.clear();

    _emitProgress(errorMessage: errorMsg, failureReason: _lastFailureReason);
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

    // If cancelled before completion, remove incomplete destination file and checkpoint
    try {
      if (await destinationFile.exists()) {
        await destinationFile.delete();
        debugPrint('[FluxShare-Storage] Deleted incomplete receiver file upon cancellation: ');
      }
    } catch (_) {}
    try {
      await ChunkPersistenceManager().deleteCheckpoint(manifest.fileId);
    } catch (_) {}

    try {
      webSocketService?.notifyTransferCancelled();
    } catch (_) {}

    _emitProgress();
    if (_completionCompleter != null && !_completionCompleter!.isCompleted) {
      _completionCompleter!.complete(false);
    }
  }

  void _emitProgress({String? errorMessage, TransferFailureReason? failureReason}) {
    final metrics = _metricsCalculator.update(
      totalBytesTransferred: _bytesTransferred,
      totalFileSize: manifest.fileSize,
    );

    final event = TransferProgressEvent(
      transferId: manifest.fileId,
      status: _status,
      progressPercent: progressPercent,
      bytesTransferred: _bytesTransferred,
      totalBytes: manifest.fileSize,
      speedMbPerSec: metrics.smoothedSpeedMbPerSec,
      remainingSeconds: metrics.remainingSeconds,
      errorMessage: errorMessage ?? _lastErrorMessage,
      failureReason: failureReason ?? _lastFailureReason,
      isPreviewReady: _isPreviewReady,
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
            fileId: manifest.fileId,
            localPeerId: localPeerId,
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

  Future<void> dispose() async {
    _progressTimer?.cancel();
    await _progressController.close();
    await _writerSession.close();
    _sharedDownloader.close();
    for (final worker in _workers) {
      await worker.stop();
    }
  }
}
