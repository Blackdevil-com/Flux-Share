import 'dart:async';
import 'dart:io';
import '../models/device.dart';
import '../models/file_info.dart';
import '../models/manifest.dart';
import '../models/peer.dart';
import '../models/receiver_progress.dart';
import '../models/transfer.dart';
import '../network/local_server.dart';
import '../network/websocket_service.dart';
import '../repositories/transfer_repository.dart';
import '../scheduler/chunk_scheduler.dart';
import '../scheduler/round_robin_scheduler.dart';
import 'transfer_engine.dart';

class BatchTransferItem {
  final String fileId;
  final FileInfo fileInfo;
  final Manifest manifest;
  final File? sourceFile;
  final File? destinationFile;
  TransferEngine? engine;
  TransferStatus status;
  int bytesTransferred;
  final int totalBytes;
  double progressPercent;
  double speedMbPerSec;
  int remainingSeconds;
  String? errorMessage;
  int retryCount;
  DateTime? startedAt;
  DateTime? completedAt;

  BatchTransferItem({
    required this.fileId,
    required this.fileInfo,
    required this.manifest,
    this.sourceFile,
    this.destinationFile,
    this.engine,
    this.status = TransferStatus.starting,
    this.bytesTransferred = 0,
    required this.totalBytes,
    this.progressPercent = 0.0,
    this.speedMbPerSec = 0.0,
    this.remainingSeconds = 0,
    this.errorMessage,
    this.retryCount = 0,
    this.startedAt,
    this.completedAt,
  });
}

class BatchProgressEvent {
  final String batchId;
  final int totalFiles;
  final int totalBytes;
  final int completedFiles;
  final int activeFiles;
  final int queuedFiles;
  final int failedFiles;
  final int cancelledFiles;
  final int totalBytesTransferred;
  final double overallProgressPercent;
  final double overallSpeedMbPerSec;
  final List<BatchTransferItem> items;
  final bool isCompleted;
  final bool hasFailures;
  final bool isPaused;
  final bool isCancelled;

  const BatchProgressEvent({
    required this.batchId,
    required this.totalFiles,
    required this.totalBytes,
    required this.completedFiles,
    required this.activeFiles,
    required this.queuedFiles,
    required this.failedFiles,
    required this.cancelledFiles,
    required this.totalBytesTransferred,
    required this.overallProgressPercent,
    required this.overallSpeedMbPerSec,
    required this.items,
    this.isCompleted = false,
    this.hasFailures = false,
    this.isPaused = false,
    this.isCancelled = false,
  });
}

/// Orchestrates multi-file batch transfers over P2P local swarm.
/// Reuses existing per-file TransferEngine with independent isolation,
/// ensuring chunks from different files never mix, while calculating
/// byte-weighted overall progress and preserving independent file history.
class BatchTransferCoordinator {
  final String batchId;
  final List<BatchTransferItem> items;
  final List<PeerInfo> swarmPeers;
  final LocalServer localServer;
  final WebSocketService? webSocketService;
  final String localPeerId;
  final String coordinatorPeerId;
  final ChunkScheduler scheduler;
  final int concurrentWorkers;
  final String networkMode;
  final bool isHost;
  final List<Device> receivers;

  final _progressController = StreamController<BatchProgressEvent>.broadcast();
  StreamSubscription<TransferProgressEvent>? _activeEngineSub;
  bool _isCancelled = false;
  bool _isPaused = false;
  int _currentIndex = 0;
  Completer<bool>? _batchCompleter;

  BatchTransferCoordinator({
    required this.batchId,
    required this.items,
    required this.swarmPeers,
    required this.localServer,
    this.webSocketService,
    required this.localPeerId,
    required this.coordinatorPeerId,
    ChunkScheduler? scheduler,
    this.concurrentWorkers = 5,
    this.networkMode = 'wifi',
    this.isHost = false,
    this.receivers = const [],
  }) : scheduler = scheduler ?? RoundRobinScheduler();

  Stream<BatchProgressEvent> get progressStream => _progressController.stream;
  List<BatchTransferItem> get currentItems => List.unmodifiable(items);
  bool get isCancelled => _isCancelled;
  bool get isPaused => _isPaused;

  int get totalBytes => items.fold(0, (sum, item) => sum + item.totalBytes);

  int get totalBytesTransferred =>
      items.fold(0, (sum, item) => sum + item.bytesTransferred);

  double get overallProgressPercent {
    final tBytes = totalBytes;
    if (tBytes <= 0) {
      final allDone = items.isNotEmpty &&
          items.every((i) => i.status == TransferStatus.completed);
      return allDone ? 100.0 : 0.0;
    }
    final ratio = (totalBytesTransferred / tBytes) * 100.0;
    return ratio.clamp(0.0, 100.0);
  }

  /// Starts or resumes the batch transfer queue.
  Future<bool> start() async {
    if (_isCancelled) return false;
    _batchCompleter = Completer<bool>();
    _isPaused = false;

    _emitProgress();
    unawaited(_processQueue());

    return _batchCompleter!.future;
  }

  Future<void> _processQueue() async {
    for (int i = 0; i < items.length; i++) {
      if (_isCancelled) break;
      _currentIndex = i;
      final item = items[i];

      // Skip already completed files
      if (item.status == TransferStatus.completed) continue;

      item.status = TransferStatus.transferring;
      item.startedAt = DateTime.now();
      _emitProgress();

      final targetFile = item.destinationFile ?? item.sourceFile;
      if (targetFile == null) {
        item.status = TransferStatus.failed;
        item.errorMessage = 'Target file reference is missing';
        _recordHistory(item);
        _emitProgress();
        continue;
      }

      // Initialize independent TransferEngine for this file
      final engine = TransferEngine(
        manifest: item.manifest,
        destinationFile: targetFile,
        swarmPeers: swarmPeers,
        localServer: localServer,
        webSocketService: webSocketService,
        localPeerId: localPeerId,
        coordinatorPeerId: coordinatorPeerId,
        concurrentWorkers: concurrentWorkers,
        scheduler: scheduler,
        networkMode: networkMode,
      );
      item.engine = engine;
      TransferRepository().registerEngine(item.fileId, engine);

      // Subscribe to engine progress
      await _activeEngineSub?.cancel();
      _activeEngineSub = engine.progressStream.listen((event) {
        item.bytesTransferred = event.bytesTransferred;
        item.progressPercent = event.progressPercent;
        item.speedMbPerSec = event.speedMbPerSec;
        item.remainingSeconds = event.remainingSeconds;
        _emitProgress();
      });

      // Execute transfer for this file
      final success = await engine.start();
      await _activeEngineSub?.cancel();
      _activeEngineSub = null;

      if (_isCancelled) {
        item.status = TransferStatus.cancelled;
        _recordHistory(item);
        break;
      }

      if (success) {
        item.status = TransferStatus.completed;
        item.bytesTransferred = item.totalBytes;
        item.progressPercent = 100.0;
        item.completedAt = DateTime.now();
      } else {
        item.status = TransferStatus.failed;
        item.errorMessage = engine.status == TransferStatus.failed
            ? 'Verification or chunk download failed'
            : 'Transfer terminated';
      }

      _recordHistory(item);
      _emitProgress();
    }

    final hasIncomplete = items.any(
      (item) =>
          item.status != TransferStatus.completed &&
          item.status != TransferStatus.failed,
    );
    final hasFailed = items.any((item) => item.status == TransferStatus.failed);

    if (!_isCancelled && !hasIncomplete) {
      if (_batchCompleter != null && !_batchCompleter!.isCompleted) {
        _batchCompleter!.complete(!hasFailed);
      }
    }

    _emitProgress();
  }

  /// Retries a single failed file by identifier.
  Future<bool> retryFile(String fileId) async {
    final item = items.firstWhere(
      (i) => i.fileId == fileId,
      orElse: () => throw ArgumentError('File $fileId not in batch'),
    );

    if (item.status == TransferStatus.completed) return true;

    item.status = TransferStatus.starting;
    item.retryCount++;
    item.errorMessage = null;
    item.bytesTransferred = 0;
    item.progressPercent = 0.0;
    _emitProgress();

    final targetFile = item.destinationFile ?? item.sourceFile;
    if (targetFile == null) return false;

    final engine = TransferEngine(
      manifest: item.manifest,
      destinationFile: targetFile,
      swarmPeers: swarmPeers,
      localServer: localServer,
      webSocketService: webSocketService,
      localPeerId: localPeerId,
      coordinatorPeerId: coordinatorPeerId,
      concurrentWorkers: concurrentWorkers,
      scheduler: scheduler,
      networkMode: networkMode,
    );
    item.engine = engine;
    TransferRepository().registerEngine(item.fileId, engine);

    await _activeEngineSub?.cancel();
    _activeEngineSub = engine.progressStream.listen((event) {
      item.bytesTransferred = event.bytesTransferred;
      item.progressPercent = event.progressPercent;
      item.speedMbPerSec = event.speedMbPerSec;
      item.remainingSeconds = event.remainingSeconds;
      _emitProgress();
    });

    item.status = TransferStatus.transferring;
    final success = await engine.start();
    await _activeEngineSub?.cancel();
    _activeEngineSub = null;

    if (success) {
      item.status = TransferStatus.completed;
      item.bytesTransferred = item.totalBytes;
      item.progressPercent = 100.0;
      item.completedAt = DateTime.now();
    } else {
      item.status = TransferStatus.failed;
      item.errorMessage = 'Retry failed verification or connection';
    }

    _recordHistory(item);
    _emitProgress();
    return success;
  }

  /// Retries all failed files in the batch without retransferring completed ones.
  Future<void> retryAllFailed() async {
    final failedItems =
        items.where((i) => i.status == TransferStatus.failed).toList();
    for (final item in failedItems) {
      await retryFile(item.fileId);
    }
  }

  void pause() {
    _isPaused = true;
    if (_currentIndex < items.length) {
      items[_currentIndex].engine?.pause();
    }
    _emitProgress();
  }

  void resume() {
    _isPaused = false;
    if (_currentIndex < items.length) {
      items[_currentIndex].engine?.resume();
    }
    _emitProgress();
  }

  Future<void> cancel() async {
    _isCancelled = true;
    await _activeEngineSub?.cancel();
    _activeEngineSub = null;

    for (final item in items) {
      if (item.status == TransferStatus.transferring ||
          item.status == TransferStatus.starting) {
        item.status = TransferStatus.cancelled;
        await item.engine?.cancel();
      }
    }

    if (_batchCompleter != null && !_batchCompleter!.isCompleted) {
      _batchCompleter!.complete(false);
    }
    _emitProgress();
  }

  Future<void> dispose() async {
    await cancel();
    await _progressController.close();
  }

  void _recordHistory(BatchTransferItem item) {
    final record = Transfer(
      id: item.fileId,
      fileInfo: item.fileInfo,
      direction: isHost ? TransferDirection.sent : TransferDirection.received,
      status: item.status,
      progressPercent: item.progressPercent,
      bytesTransferred: item.bytesTransferred,
      transferSpeedMbPerSec: item.speedMbPerSec,
      remainingSeconds: item.remainingSeconds,
      timestamp: DateTime.now(),
      receivers: receivers
          .map(
            (d) => ReceiverProgress(
              deviceId: d.id,
              deviceName: d.name,
              progressPercent: item.progressPercent,
            ),
          )
          .toList(),
      chunkStats: {
        'batchId': batchId,
        'chunkCount': item.manifest.chunkCount,
        'chunkSize': item.manifest.chunkSize,
        'retryCount': item.retryCount,
      },
    );

    TransferRepository().updateTransfer(record);
  }

  void _emitProgress() {
    if (_progressController.isClosed) return;

    int completed = 0;
    int active = 0;
    int queued = 0;
    int failed = 0;
    int cancelled = 0;
    double currentSpeed = 0.0;

    for (final item in items) {
      switch (item.status) {
        case TransferStatus.completed:
          completed++;
          break;
        case TransferStatus.transferring:
        case TransferStatus.starting:
          active++;
          currentSpeed += item.speedMbPerSec;
          break;
        case TransferStatus.paused:
          active++;
          break;
        case TransferStatus.failed:
          failed++;
          break;
        case TransferStatus.cancelled:
          cancelled++;
          break;
      }
    }

    queued = items.length - (completed + active + failed + cancelled);
    if (queued < 0) queued = 0;

    _progressController.add(
      BatchProgressEvent(
        batchId: batchId,
        totalFiles: items.length,
        totalBytes: totalBytes,
        completedFiles: completed,
        activeFiles: active,
        queuedFiles: queued,
        failedFiles: failed,
        cancelledFiles: cancelled,
        totalBytesTransferred: totalBytesTransferred,
        overallProgressPercent: overallProgressPercent,
        overallSpeedMbPerSec: currentSpeed,
        items: List.of(items),
        isCompleted: completed == items.length && items.isNotEmpty,
        hasFailures: failed > 0,
        isPaused: _isPaused,
        isCancelled: _isCancelled,
      ),
    );
  }
}
