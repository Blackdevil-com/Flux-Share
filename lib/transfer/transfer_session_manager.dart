import 'dart:async';
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
    for (final r in receivers) {
      _hostReceiverProgress[r.id] = 0.0;
    }
    for (final cr in server.connectedReceivers) {
      _hostReceiverProgress[cr.peerId] = cr.progressPercent;
      _hostReceiverBytes[cr.peerId] = cr.bytesReceived;
    }

    _activeServer!.addControlListener(_handleHostControlMessage);
    _serverReceiversSub = _activeServer!.connectedReceiversStream.listen((list) {
      for (final cr in list) {
        _hostReceiverProgress[cr.peerId] = cr.progressPercent;
        _hostReceiverBytes[cr.peerId] = cr.bytesReceived;
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
    final peerId = msg['peerId'] as String? ?? 'receiver';

    if (type == 'TRANSFER_PROGRESS') {
      final percent = (msg['percent'] as num?)?.toDouble() ?? 0.0;
      final bytes = (msg['bytesTransferred'] as num?)?.toInt() ?? 0;
      final speed = (msg['speedMbPerSec'] as num?)?.toDouble() ??
          (((msg['speedBytesPerSec'] as num?)?.toDouble() ?? 0.0) / (1024 * 1024));

      _hostReceiverProgress[peerId] = percent;
      _hostReceiverBytes[peerId] = bytes;
      _hostReceiverSpeed[peerId] = speed;

      _updateHostSnapshot();
    } else if (type == 'TRANSFER_COMPLETED') {
      _hostReceiverProgress[peerId] = 100.0;
      if (_activeBatchManifest != null) {
        _hostReceiverBytes[peerId] = _activeBatchManifest!.totalBytes;
      }
      _updateHostSnapshot();
    } else if (type == 'RECEIVER_JOINED' || type == 'RECEIVER_READY' || type == 'RECEIVER_FAILED') {
      _updateHostSnapshot();
    }
  }

  void _updateHostSnapshot() {
    if (_activeBatchManifest == null) return;

    final totalBytes = _activeBatchManifest!.totalBytes;
    final totalFiles = _activeBatchManifest!.totalFiles;

    final avgProgress = _hostReceiverProgress.isNotEmpty
        ? _hostReceiverProgress.values.reduce((a, b) => a + b) / _hostReceiverProgress.length
        : 0.0;

    final maxBytes = _hostReceiverBytes.isNotEmpty
        ? _hostReceiverBytes.values.reduce((a, b) => a > b ? a : b)
        : 0;

    final totalSpeed = _hostReceiverSpeed.values.fold(0.0, (sum, s) => sum + s);

    int remainingSec = 0;
    final remainingBytes = totalBytes - maxBytes;
    if (remainingBytes > 0 && totalSpeed > 0.05) {
      remainingSec = (remainingBytes / (totalSpeed * 1024 * 1024)).ceil();
    }

    final isAllCompleted = _hostReceiverProgress.isNotEmpty &&
        _hostReceiverProgress.values.every((p) => p >= 100.0);

    final wasAlreadyCompleted = _currentSnapshot?.status == TransferStatus.completed;
    if (isAllCompleted && !wasAlreadyCompleted) {
      final sId = _activeSessionId ?? _activeBatchManifest?.batchId;
      if (sId != null) {
        unawaited(ManagedTemporaryFileService.instance.cleanupSession(
          sId,
          reason: 'host_transfer_completed',
        ));
      }
    }

    _currentSnapshot = TransferProgressSnapshot(
      sessionId: _activeBatchManifest!.batchId,
      isHost: true,
      status: isAllCompleted ? TransferStatus.completed : TransferStatus.transferring,
      progressPercent: isAllCompleted ? 100.0 : avgProgress,
      speedMbPerSec: isAllCompleted ? 0.0 : totalSpeed,
      bytesTransferred: isAllCompleted ? totalBytes : maxBytes,
      totalBytes: totalBytes,
      remainingSeconds: isAllCompleted ? 0 : remainingSec,
      completedFiles: isAllCompleted ? totalFiles : 0,
      totalFiles: totalFiles,
      currentFileName: _activeFileInfo?.name ?? '',
      receiverProgressMap: Map.from(_hostReceiverProgress),
      connectedReceivers: _activeServer?.connectedReceivers ?? [],
    );
    _emitSnapshot();

    final pctInt = _currentSnapshot!.progressPercent.clamp(0.0, 100.0).round();
    final speedStr = totalSpeed > 0
        ? '${totalSpeed.toStringAsFixed(1)} MB/s'
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
      final sId = _activeSessionId ?? _activeBatchManifest?.batchId;
      if (sId != null) {
        await ManagedTemporaryFileService.instance.cleanupSession(
          sId,
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
    final oldSessionId = _activeSessionId ?? _activeBatchManifest?.batchId;
    if (oldSessionId != null && _isHost) {
      unawaited(ManagedTemporaryFileService.instance.cleanupSession(
        oldSessionId,
        reason: 'host_session_replaced',
      ));
    }
    _activeSub?.cancel();
    _activeSub = null;
    _serverReceiversSub?.cancel();
    _serverReceiversSub = null;
    _hostReceiverBytes.clear();
    _hostReceiverSpeed.clear();
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
