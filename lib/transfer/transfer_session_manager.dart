import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/connected_receiver.dart';
import '../models/batch_manifest.dart';
import '../models/device.dart';
import '../models/file_info.dart';
import '../models/manifest.dart';
import '../models/transfer.dart';
import '../network/local_server.dart';
import '../services/background_transfer_service.dart';
import '../services/managed_temporary_file_service.dart';
import 'batch_transfer_coordinator.dart';
import 'transfer_engine.dart';
import '../discovery/discovery_service.dart';
import '../room/room_manager.dart';

/// Represents an authoritative point-in-time snapshot of the active transfer session.
class TransferProgressSnapshot {
  final String sessionId;
  final bool isHost;
  final TransferStatus status;
  final double progressPercent;
  final double speedMbPerSec;
  final int bytesTransferred;
  final int totalBytes;
  final int remainingSeconds;
  final int completedFiles;
  final int totalFiles;
  final String currentFileName;
  final List<BatchTransferItem> items;
  final Map<String, double> receiverProgressMap;
  final Map<String, int> peerChunkContributions;
  final List<ConnectedReceiver> connectedReceivers;
  final String? errorMessage;
  final bool isPreviewReady;

  const TransferProgressSnapshot({
    required this.sessionId,
    required this.isHost,
    required this.status,
    required this.progressPercent,
    required this.speedMbPerSec,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.remainingSeconds,
    this.completedFiles = 0,
    this.totalFiles = 1,
    this.currentFileName = '',
    this.items = const [],
    this.receiverProgressMap = const {},
    this.peerChunkContributions = const {},
    this.connectedReceivers = const [],
    this.errorMessage,
    this.isPreviewReady = false,
  });

  bool get isCompleted => status == TransferStatus.completed;
  bool get isPaused => status == TransferStatus.paused;
  bool get isCancelled => status == TransferStatus.cancelled;
  bool get isFailed => status == TransferStatus.failed;
  bool get isTransferring => status == TransferStatus.transferring;
  int get activeReceiverCount => connectedReceivers.where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed).length;

  String get formattedRemainingTime {
    if (isPaused) return 'Paused';
    if (progressPercent >= 100.0) return '00:00';
    if (speedMbPerSec <= 0.05 && remainingSeconds <= 0) return '--:--';
    final mins = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (remainingSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }
}

/// Decoupled, lifecycle-independent coordinator that manages active transfers.
/// Keeps transfers active when the Flutter UI is disposed, screen turns off,
/// or user navigates between screens. Bridges to Android foreground service.
class TransferSessionManager {
  static final TransferSessionManager _instance =
      TransferSessionManager._internal();

  factory TransferSessionManager() => _instance;
  static TransferSessionManager get instance => _instance;

  final StreamController<TransferProgressSnapshot> _progressController =
      StreamController<TransferProgressSnapshot>.broadcast();

  TransferProgressSnapshot? _currentSnapshot;
  BatchTransferCoordinator? _activeCoordinator;
  TransferEngine? _activeSingleEngine;
  LocalServer? _activeServer;
  StreamSubscription? _activeSub;

  final Map<String, double> _hostReceiverProgress = {};
  final Map<String, int> _hostReceiverBytes = {};
  final Map<String, double> _hostReceiverSpeed = {};
  StreamSubscription? _serverReceiversSub;
  List<Device> _activeReceivers = [];
  FileInfo? _activeFileInfo;
  BatchManifest? _activeBatchManifest;
  Manifest? _activeManifest;
  String? _roomPin;
  String? _activeSessionId;
  bool _isHost = false;
  bool _hostCompletedEmitted = false;
  double _displayedProgressPercent = 0.0;
  double _lastEffectiveSpeed = 0.0;
  DateTime? _lastHostSnapshotTime;
  int _lastHostBytesTransferred = 0;

  TransferSessionManager._internal() {
    BackgroundTransferService.instance.addCancelListener(() {
      debugPrint('[TransferSessionManager] Notification cancel triggered');
      cancel();
    });
  }

  Stream<TransferProgressSnapshot> get progressStream =>
      _progressController.stream;
  TransferProgressSnapshot? get currentSnapshot => _currentSnapshot;
  bool get hasActiveSession =>
      _currentSnapshot != null &&
      !_currentSnapshot!.isCompleted &&
      !_currentSnapshot!.isCancelled &&
      !_currentSnapshot!.isFailed;

  bool get isHost => _isHost;
  List<Device> get activeReceivers => List.unmodifiable(_activeReceivers);
  FileInfo? get activeFileInfo => _activeFileInfo;
  BatchManifest? get activeBatchManifest => _activeBatchManifest;
  Manifest? get activeManifest => _activeManifest;
  String? get roomPin => _roomPin;
  BatchTransferCoordinator? get activeCoordinator => _activeCoordinator;
  TransferEngine? get activeSingleEngine => _activeSingleEngine;

  /// Starts a host (sender) transfer session.
  Future<void> startHostSession({
    required LocalServer server,
    required BatchManifest batchManifest,
    required List<Device> receivers,
    required String? roomPin,
    String? sessionId,
  }) async {
    _cleanExistingSession();

    _isHost = true;
    _hostCompletedEmitted = false;
    _activeSessionId = sessionId ?? batchManifest.batchId;
    _activeServer = server;
    _activeBatchManifest = batchManifest;
    _activeReceivers = receivers;
    _roomPin = roomPin;
    _activeFileInfo = batchManifest.manifests.isNotEmpty
        ? FileInfo(
            id: batchManifest.manifests.first.fileId,
            name: batchManifest.manifests.first.fileName,
            sizeBytes: batchManifest.manifests.first.fileSize,
            formattedSize: batchManifest.formattedTotalSize,
            extension: batchManifest.manifests.first.fileName.split('.').last,
            type: FileType.Other,
          )
        : null;

    _hostReceiverProgress.clear();
    _hostReceiverBytes.clear();
    _hostReceiverSpeed.clear();
    _lastHostSnapshotTime = null;
    _lastHostBytesTransferred = 0;
    _lastEffectiveSpeed = 0.0;
    _displayedProgressPercent = 0.0;
    for (final r in receivers) {
      _hostReceiverProgress[r.id] = 0.0;
      _hostReceiverBytes[r.id] = 0;
    }
    final batchTotalBytes = batchManifest.totalBytes;
    for (final cr in server.connectedReceivers) {
      final clampedPct = cr.progressPercent.clamp(0.0, 100.0);
      final clampedBytes = batchTotalBytes > 0
          ? cr.bytesReceived.clamp(0, batchTotalBytes)
          : max(0, cr.bytesReceived);
      _hostReceiverProgress[cr.peerId] = clampedPct;
      _hostReceiverBytes[cr.peerId] = clampedBytes;
    }

    _activeServer!.addControlListener(_handleHostControlMessage);
    _serverReceiversSub = _activeServer!.connectedReceiversStream.listen((list) {
      final totalB = _activeBatchManifest?.totalBytes ?? 0;
      for (final cr in list) {
        final currentP = _hostReceiverProgress[cr.peerId] ?? 0.0;
        final currentB = _hostReceiverBytes[cr.peerId] ?? 0;
        final clampedP = cr.progressPercent.clamp(0.0, 100.0);
        final clampedB = totalB > 0
            ? cr.bytesReceived.clamp(0, totalB)
            : max(0, cr.bytesReceived);

        _hostReceiverProgress[cr.peerId] = max(currentP, clampedP);
        _hostReceiverBytes[cr.peerId] = max(currentB, clampedB);
      }
      _updateHostSnapshot();
    });

    final totalFiles = batchManifest.totalFiles;
    final totalBytes = batchManifest.totalBytes;

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: batchManifest.batchId,
      isHost: true,
      status: TransferStatus.transferring,
      progressPercent: 0.0,
      speedMbPerSec: 0.0,
      bytesTransferred: 0,
      totalBytes: totalBytes,
      remainingSeconds: 0,
      completedFiles: 0,
      totalFiles: totalFiles,
      currentFileName: batchManifest.manifests.first.fileName,
      receiverProgressMap: Map.from(_hostReceiverProgress),
      connectedReceivers: server.connectedReceivers,
    );
    _emitSnapshot();

    await BackgroundTransferService.instance.startForeground(
      title: 'FluxShare — Hosting $totalFiles file${totalFiles > 1 ? 's' : ''}',
      message: 'Waiting for receivers to download...',
      progress: 0,
      maxProgress: 100,
    );
  }

  /// Starts a receiver transfer session with a BatchTransferCoordinator.
  Future<void> startReceiverBatchSession({
    required BatchTransferCoordinator coordinator,
    required BatchManifest batchManifest,
  }) async {
    _cleanExistingSession();

    _isHost = false;
    _activeCoordinator = coordinator;
    _activeBatchManifest = batchManifest;
    _activeFileInfo = coordinator.items.isNotEmpty
        ? coordinator.items.first.fileInfo
        : null;

    final totalFiles = coordinator.items.length;
    final totalBytes = coordinator.totalBytes;

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: coordinator.batchId,
      isHost: false,
      status: TransferStatus.transferring,
      progressPercent: 0.0,
      speedMbPerSec: 0.0,
      bytesTransferred: 0,
      totalBytes: totalBytes,
      remainingSeconds: 0,
      completedFiles: 0,
      totalFiles: totalFiles,
      currentFileName: coordinator.items.isNotEmpty
          ? coordinator.items.first.fileInfo.name
          : '',
      items: coordinator.items,
    );
    _emitSnapshot();

    await BackgroundTransferService.instance.startForeground(
      title: 'FluxShare — Receiving $totalFiles file${totalFiles > 1 ? 's' : ''}',
      message: 'Starting parallel download...',
      progress: 0,
      maxProgress: 100,
    );

    _activeSub = coordinator.progressStream.listen(_handleBatchEvent);
  }

  /// Starts a receiver single-engine transfer session.
  Future<void> startReceiverSingleSession({
    required TransferEngine engine,
    required Manifest manifest,
    required FileInfo fileInfo,
  }) async {
    _cleanExistingSession();

    _isHost = false;
    _activeSingleEngine = engine;
    _activeManifest = manifest;
    _activeFileInfo = fileInfo;

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: manifest.fileId,
      isHost: false,
      status: TransferStatus.transferring,
      progressPercent: 0.0,
      speedMbPerSec: 0.0,
      bytesTransferred: 0,
      totalBytes: manifest.fileSize,
      remainingSeconds: 0,
      completedFiles: 0,
      totalFiles: 1,
      currentFileName: manifest.fileName,
    );
    _emitSnapshot();

    await BackgroundTransferService.instance.startForeground(
      title: 'FluxShare — Receiving ${manifest.fileName}',
      message: 'Starting download...',
      progress: 0,
      maxProgress: 100,
    );

    _activeSub = engine.progressStream.listen(_handleSingleEngineEvent);
  }

  void _handleBatchEvent(BatchProgressEvent event) {
    final activeItem = event.items.firstWhere(
      (i) => i.status == TransferStatus.transferring,
      orElse: () => event.items.isNotEmpty ? event.items.last : event.items.first,
    );

    final status = event.isCompleted
        ? TransferStatus.completed
        : event.isCancelled
            ? TransferStatus.cancelled
            : event.isPaused
                ? TransferStatus.paused
                : TransferStatus.transferring;

    // Aggregate peer contributions across items
    final peerContributions = <String, int>{};
    if (activeItem.engine != null) {
      peerContributions.addAll(activeItem.engine!.peerChunkContributions);
    }

    // Estimate remaining seconds based on overall speed
    int remainingSec = 0;
    final remainingBytes = event.totalBytes - event.totalBytesTransferred;
    if (remainingBytes > 0 && event.overallSpeedMbPerSec > 0.05) {
      remainingSec =
          (remainingBytes / (event.overallSpeedMbPerSec * 1024 * 1024)).ceil();
    }

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: event.batchId,
      isHost: false,
      status: status,
      progressPercent: event.overallProgressPercent,
      speedMbPerSec: event.overallSpeedMbPerSec,
      bytesTransferred: event.totalBytesTransferred,
      totalBytes: event.totalBytes,
      remainingSeconds: remainingSec,
      completedFiles: event.completedFiles,
      totalFiles: event.totalFiles,
      currentFileName: activeItem.fileInfo.name,
      items: event.items,
      peerChunkContributions: peerContributions,
      isPreviewReady: activeItem.engine?.isPreviewReady ?? false,
    );
    _emitSnapshot();

    final pctInt = event.overallProgressPercent.clamp(0.0, 100.0).round();
    final speedStr = event.overallSpeedMbPerSec > 0
        ? '${event.overallSpeedMbPerSec.toStringAsFixed(1)} MB/s'
        : 'Connecting...';
    final remainingStr = _currentSnapshot!.formattedRemainingTime;

    BackgroundTransferService.instance.updateProgress(
      title:
          'FluxShare — Receiving (${event.completedFiles + 1}/${event.totalFiles}) [$pctInt%]',
      message: '$speedStr • ETA: $remainingStr',
      progress: pctInt,
      maxProgress: 100,
    );

    if (event.isCompleted || event.isCancelled || event.hasFailures) {
      BackgroundTransferService.instance.stopForeground();
    }
  }

  void _handleSingleEngineEvent(TransferProgressEvent event) {
    _currentSnapshot = TransferProgressSnapshot(
      sessionId: event.transferId,
      isHost: false,
      status: event.status,
      progressPercent: event.progressPercent,
      speedMbPerSec: event.speedMbPerSec,
      bytesTransferred: event.bytesTransferred,
      totalBytes: event.totalBytes,
      remainingSeconds: event.remainingSeconds,
      completedFiles: event.status == TransferStatus.completed ? 1 : 0,
      totalFiles: 1,
      currentFileName: _activeManifest?.fileName ?? 'File',
      errorMessage: event.errorMessage,
      peerChunkContributions:
          _activeSingleEngine?.peerChunkContributions ?? {},
      isPreviewReady: event.isPreviewReady,
    );
    _emitSnapshot();

    final pctInt = event.progressPercent.clamp(0.0, 100.0).round();
    final speedStr = event.speedMbPerSec > 0
        ? '${event.speedMbPerSec.toStringAsFixed(1)} MB/s'
        : 'Connecting...';
    final remainingStr = _currentSnapshot!.formattedRemainingTime;

    BackgroundTransferService.instance.updateProgress(
      title: 'FluxShare — Receiving [$pctInt%]',
      message: '$speedStr • ETA: $remainingStr',
      progress: pctInt,
      maxProgress: 100,
    );

    if (event.status == TransferStatus.completed ||
        event.status == TransferStatus.cancelled ||
        event.status == TransferStatus.failed) {
      BackgroundTransferService.instance.stopForeground();
    }
  }

  void _handleHostControlMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    String peerId = msg['peerId'] as String? ?? '';
    if (peerId.isEmpty) {
      if (_hostReceiverProgress.length == 1) {
        peerId = _hostReceiverProgress.keys.first;
      } else if (_activeServer?.connectedReceivers.length == 1) {
        peerId = _activeServer!.connectedReceivers.first.peerId;
      } else {
        peerId = 'receiver';
      }
    }

    if (type == 'TRANSFER_PROGRESS') {
      final rawPercent = (msg['percent'] as num?)?.toDouble();
      final rawBytes = (msg['bytesTransferred'] as num?)?.toInt();
      final rawSpeed = (msg['speedMbPerSec'] as num?)?.toDouble() ??
          (((msg['speedBytesPerSec'] as num?)?.toDouble() ?? 0.0) / (1024 * 1024));

      // Discard invalid / NaN inputs
      if (rawPercent != null && (rawPercent.isNaN || rawPercent.isInfinite)) return;
      if (rawSpeed.isNaN || rawSpeed.isInfinite) return;

      final totalBytes = _activeBatchManifest?.totalBytes ?? 0;
      final clampedPercent = (rawPercent ?? 0.0).clamp(0.0, 100.0);
      final clampedBytes = totalBytes > 0
          ? (rawBytes ?? 0).clamp(0, totalBytes)
          : max(0, rawBytes ?? 0);

      final currentProgress = _hostReceiverProgress[peerId] ?? 0.0;
      final currentBytes = _hostReceiverBytes[peerId] ?? 0;

      // Drop stale out-of-order progress updates that would regress this receiver's progress
      if (clampedPercent < currentProgress && clampedBytes <= currentBytes) {
        return;
      }

      final effectiveProgress = max(currentProgress, clampedPercent);
      final effectiveBytes = max(currentBytes, clampedBytes);

      _hostReceiverProgress[peerId] = effectiveProgress;
      _hostReceiverBytes[peerId] = effectiveBytes;
      if (rawSpeed >= 0.0) {
        _hostReceiverSpeed[peerId] = rawSpeed;
      }

      _updateHostSnapshot();
    } else if (type == 'TRANSFER_COMPLETED') {
      _hostReceiverProgress[peerId] = 100.0;
      if (_activeBatchManifest != null) {
        _hostReceiverBytes[peerId] = _activeBatchManifest!.totalBytes;
      }
      _updateHostSnapshot();
    } else if (type == 'RECEIVER_JOINED' || type == 'RECEIVER_READY') {
      if (!_hostReceiverProgress.containsKey(peerId)) {
        _hostReceiverProgress[peerId] = 0.0;
        _hostReceiverBytes[peerId] = 0;
      }
      _updateHostSnapshot();
    } else if (type == 'RECEIVER_FAILED') {
      _updateHostSnapshot();
    }
  }

  void _updateHostSnapshot() {
    if (_activeBatchManifest == null) return;

    final connected = _activeServer?.connectedReceivers ?? [];
    final connectedPeerIds = connected.map((c) => c.peerId).toSet();
    final expectedPeerIds = _activeReceivers.map((r) => r.id).toSet();
    final allKnownPeerIds = connectedPeerIds.union(expectedPeerIds);

    // Clean up temporary receivers that disconnected with 0 bytes and were not pre-selected
    _hostReceiverProgress.removeWhere(
      (k, v) =>
          !connectedPeerIds.contains(k) &&
          !expectedPeerIds.contains(k) &&
          (!_hostReceiverBytes.containsKey(k) || _hostReceiverBytes[k] == 0),
    );

    // Ensure all connected or expected receivers are tracked
    for (final id in allKnownPeerIds) {
      _hostReceiverProgress.putIfAbsent(id, () => 0.0);
      _hostReceiverBytes.putIfAbsent(id, () => 0);
    }

    final totalBytes = _activeBatchManifest!.totalBytes;
    final totalFiles = _activeBatchManifest!.totalFiles;

    // Calculate truthful raw aggregate progress across all tracked receivers
    final rawAggregateProgress = _hostReceiverProgress.isNotEmpty
        ? (_hostReceiverProgress.values.reduce((a, b) => a + b) /
                _hostReceiverProgress.length)
            .clamp(0.0, 100.0)
        : 0.0;

    // Maintain monotonic aggregate displayed progress so late joiners do not jump the bar backwards
    _displayedProgressPercent =
        max(_displayedProgressPercent, rawAggregateProgress).clamp(0.0, 100.0);

    // Consistent bytesTransferred derived directly from displayed progress
    final bytesTransferred = totalBytes > 0
        ? ((_displayedProgressPercent / 100.0) * totalBytes)
            .round()
            .clamp(0, totalBytes)
        : 0;

    // Sum of bytes delivered across all receivers
    final totalBytesDelivered =
        _hostReceiverBytes.values.fold(0, (sum, b) => sum + b);

    final reportedSpeed = _hostReceiverSpeed.values.fold(0.0, (sum, s) => sum + s);
    double effectiveSpeed = reportedSpeed;

    final now = DateTime.now();
    if (_lastHostSnapshotTime != null) {
      final elapsedMs = now.difference(_lastHostSnapshotTime!).inMilliseconds;
      if (elapsedMs >= 200) {
        final bytesDiff = totalBytesDelivered - _lastHostBytesTransferred;
        if (bytesDiff > 0 && elapsedMs < 10000) {
          final instantSpeed =
              (bytesDiff / (1024 * 1024)) / (elapsedMs / 1000.0);
          if (instantSpeed > effectiveSpeed) {
            effectiveSpeed = instantSpeed;
          }
        }
        if (_lastEffectiveSpeed > 0) {
          effectiveSpeed = 0.7 * effectiveSpeed + 0.3 * _lastEffectiveSpeed;
        }
        _lastHostSnapshotTime = now;
        _lastHostBytesTransferred = totalBytesDelivered;
        _lastEffectiveSpeed = effectiveSpeed;
      }
    } else {
      _lastHostSnapshotTime = now;
      _lastHostBytesTransferred = totalBytesDelivered;
      _lastEffectiveSpeed = effectiveSpeed;
    }

    // Truthful completion decision based on real receiver progress, not clamped display percentage
    final hasRequiredReceivers = _activeReceivers.isNotEmpty
        ? expectedPeerIds.every((id) => (_hostReceiverProgress[id] ?? 0.0) >= 100.0)
        : (connectedPeerIds.isNotEmpty
            ? connectedPeerIds.every((id) => (_hostReceiverProgress[id] ?? 0.0) >= 100.0)
            : (_hostReceiverProgress.isNotEmpty &&
                _hostReceiverProgress.values.every((p) => p >= 100.0)));

    final isAllCompleted = hasRequiredReceivers &&
        _hostReceiverProgress.isNotEmpty &&
        _hostReceiverProgress.values.every((p) => p >= 100.0);

    final hasFailed = connected.isNotEmpty &&
        connected.every((r) => r.status == ReceiverStatus.failed);

    if (isAllCompleted) {
      if (_hostCompletedEmitted) return;
      _hostCompletedEmitted = true;
      effectiveSpeed = 0.0;
      final sId = _activeSessionId;
      final bId = _activeBatchManifest?.batchId;
      if (sId != null) {
        unawaited(ManagedTemporaryFileService.instance.cleanupSession(
          sId,
          reason: 'host_transfer_completed',
        ));
      }
      if (bId != null && bId != sId) {
        unawaited(ManagedTemporaryFileService.instance.cleanupSession(
          bId,
          reason: 'host_transfer_completed',
        ));
      }
    }

    // ETA calculation corresponding to the exact same progress metric
    int remainingSec = -1;
    final remainingBytes = totalBytes - bytesTransferred;
    if (isAllCompleted || remainingBytes <= 0) {
      remainingSec = 0;
    } else if (effectiveSpeed > 0.05) {
      remainingSec = (remainingBytes / (effectiveSpeed * 1024 * 1024)).ceil();
    } else {
      remainingSec = -1; // Waiting / unknown ETA
    }

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: _activeBatchManifest!.batchId,
      isHost: true,
      status: isAllCompleted
          ? TransferStatus.completed
          : (hasFailed ? TransferStatus.failed : TransferStatus.transferring),
      progressPercent: isAllCompleted ? 100.0 : _displayedProgressPercent,
      speedMbPerSec: isAllCompleted ? 0.0 : effectiveSpeed,
      bytesTransferred: isAllCompleted ? totalBytes : bytesTransferred,
      totalBytes: totalBytes,
      remainingSeconds: remainingSec,
      completedFiles: isAllCompleted ? totalFiles : 0,
      totalFiles: totalFiles,
      currentFileName: _activeFileInfo?.name ?? '',
      receiverProgressMap: Map.unmodifiable(_hostReceiverProgress),
      connectedReceivers: _activeServer?.connectedReceivers ?? [],
    );
    _emitSnapshot();

    final pctInt = _currentSnapshot!.progressPercent.clamp(0.0, 100.0).round();
    final speedStr = effectiveSpeed > 0
        ? '${effectiveSpeed.toStringAsFixed(1)} MB/s'
        : 'Connecting...';
    final remainingStr = _currentSnapshot!.formattedRemainingTime;

    BackgroundTransferService.instance.updateProgress(
      title: isAllCompleted
          ? 'FluxShare — Transfer Completed'
          : 'FluxShare — Hosting Transfer [$pctInt%]',
      message: isAllCompleted
          ? 'All receivers finished downloading'
          : '$speedStr • ETA: $remainingStr',
      progress: pctInt,
      maxProgress: 100,
    );

    if (isAllCompleted) {
      BackgroundTransferService.instance.stopForeground();
    }
  }

  void pause() {
    if (_activeCoordinator != null) {
      _activeCoordinator!.pause();
    } else if (_activeSingleEngine != null) {
      _activeSingleEngine!.pause();
    }
    BackgroundTransferService.instance.updateProgress(
      title: 'FluxShare — Transfer Paused',
      message: 'Tap to resume',
      progress: (_currentSnapshot?.progressPercent ?? 0).round(),
      maxProgress: 100,
      force: true,
    );
  }

  void resume() {
    if (_activeCoordinator != null) {
      _activeCoordinator!.resume();
    } else if (_activeSingleEngine != null) {
      _activeSingleEngine!.resume();
    }
  }

  Future<void> cancel() async {
    await _activeSub?.cancel();
    _activeSub = null;

    if (_activeCoordinator != null) {
      await _activeCoordinator!.cancel();
      _activeCoordinator = null;
    }
    if (_activeSingleEngine != null) {
      await _activeSingleEngine!.cancel();
      _activeSingleEngine = null;
    }
    if (_isHost) {
      DiscoveryService().stopRoomHost();
      RoomManager().expireRoom();
      if (_activeServer != null) {
        _activeServer!.clearBatch();
        _activeServer!.removeControlListener(_handleHostControlMessage);
      }
      final sId = _activeSessionId;
      final bId = _activeBatchManifest?.batchId;
      if (sId != null) {
        await ManagedTemporaryFileService.instance.cleanupSession(
          sId,
          reason: 'host_session_cancelled',
        );
      }
      if (bId != null && bId != sId) {
        await ManagedTemporaryFileService.instance.cleanupSession(
          bId,
          reason: 'host_session_cancelled',
        );
      }
    }

    await BackgroundTransferService.instance.stopForeground();

    if (_currentSnapshot != null) {
      _currentSnapshot = TransferProgressSnapshot(
        sessionId: _currentSnapshot!.sessionId,
        isHost: _isHost,
        status: TransferStatus.cancelled,
        progressPercent: _currentSnapshot!.progressPercent,
        speedMbPerSec: 0.0,
        bytesTransferred: _currentSnapshot!.bytesTransferred,
        totalBytes: _currentSnapshot!.totalBytes,
        remainingSeconds: 0,
        completedFiles: _currentSnapshot!.completedFiles,
        totalFiles: _currentSnapshot!.totalFiles,
        currentFileName: _currentSnapshot!.currentFileName,
      );
      _emitSnapshot();
    }
  }

  void _cleanExistingSession() {
    final oldSessionId = _activeSessionId;
    final oldBatchId = _activeBatchManifest?.batchId;
    if (oldSessionId != null && _isHost) {
      unawaited(ManagedTemporaryFileService.instance.cleanupSession(
        oldSessionId,
        reason: 'host_session_replaced',
      ));
    }
    if (oldBatchId != null && oldBatchId != oldSessionId && _isHost) {
      unawaited(ManagedTemporaryFileService.instance.cleanupSession(
        oldBatchId,
        reason: 'host_session_replaced',
      ));
    }
    _activeSub?.cancel();
    _activeSub = null;
    _serverReceiversSub?.cancel();
    _serverReceiversSub = null;
    _hostReceiverProgress.clear();
    _hostReceiverBytes.clear();
    _hostReceiverSpeed.clear();
    _lastHostSnapshotTime = null;
    _lastHostBytesTransferred = 0;
    _lastEffectiveSpeed = 0.0;
    _displayedProgressPercent = 0.0;
    _hostCompletedEmitted = false;
    if (_activeServer != null) {
      _activeServer!.removeControlListener(_handleHostControlMessage);
    }
  }

  void _emitSnapshot() {
    if (_currentSnapshot != null && !_progressController.isClosed) {
      _progressController.add(_currentSnapshot!);
    }
  }

  void dispose() {
    _cleanExistingSession();
    _progressController.close();
  }
}
