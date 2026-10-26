import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../ai/ai_models.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../../models/models.dart';
import '../../models/connected_receiver.dart';
import '../../network/local_server.dart';
import '../../network/network_utils.dart';
import '../../repositories/transfer_repository.dart';
import '../../transfer/batch_transfer_coordinator.dart';
import '../../transfer/transfer_engine.dart';
import '../../transfer/transfer_session_manager.dart';
import '../../widgets/widgets.dart';
import 'transfer_complete_screen.dart';
import '../../discovery/discovery_service.dart';
import '../../room/room_manager.dart';

class TransferProgressScreen extends StatefulWidget {
  final FileInfo? fileInfo;
  final List<Device>? receivers;
  final TransferEngine? engine;
  final File? destinationFile;
  final File? sourceFile;
  final Manifest? manifest;
  final BatchManifest? batchManifest;
  final List<File>? sourceFiles;
  final BatchTransferCoordinator? batchCoordinator;
  final bool isHost;
  final String? roomPin;

  const TransferProgressScreen({
    super.key,
    this.fileInfo,
    this.receivers,
    this.engine,
    this.destinationFile,
    this.sourceFile,
    this.manifest,
    this.batchManifest,
    this.sourceFiles,
    this.batchCoordinator,
    this.isHost = false,
    this.roomPin,
  });

  @override
  State<TransferProgressScreen> createState() => _TransferProgressScreenState();
}

class _TransferProgressScreenState extends State<TransferProgressScreen> {
  late FileInfo _file;
  late List<Device> _receiverDevices;

  double _progressPercent = 0.0;
  double _speedMbPerSec = 0.0;
  int _bytesTransferred = 0;
  int _remainingSeconds = 0;
  bool _isPaused = false;
  bool _isCancelled = false;

  AITransferOptimization? _currentOptimization;
  AIFailureDiagnosis? _currentDiagnosis;
  bool _optimizationApplied = false;

  StreamSubscription<TransferProgressSnapshot>? _sessionSub;
  StreamSubscription<TransferProgressEvent>? _engineSub;
  StreamSubscription<BatchProgressEvent>? _batchSub;
  BatchProgressEvent? _batchEvent;
  BatchTransferCoordinator? _activeCoordinator;
  Map<String, int> _peerContributions = {};
  List<BatchTransferItem> _batchItems = [];

  bool _isPreviewReady = false;
  final Map<String, double> _receiverProgressMap = {};
  List<ConnectedReceiver> _liveReceivers = [];
  StreamSubscription<List<ConnectedReceiver>>? _liveReceiversSub;

  @override
  void initState() {
    super.initState();
    _file = widget.fileInfo ??
        const FileInfo(
          id: 'file_transfer',
          name: 'File Transfer',
          sizeBytes: 0,
          formattedSize: '0 B',
          extension: '',
          type: FileType.Other,
        );

    _receiverDevices = widget.receivers ?? [];

    final aiService = AIService();
    if (aiService.config.isAiEnabled) {
      _currentOptimization = aiService.optimizer.recommendOptimization(
        fileSize: _file.sizeBytes,
        currentSpeedMbPerSec: 15.0,
        avgLatencyMillis: 60.0,
        completedChunks: 1,
        retransmissionCount: 0,
      );
      _currentDiagnosis = AIFailureDiagnosis.normal;
    }

    final sessionManager = TransferSessionManager.instance;
    if (sessionManager.hasActiveSession) {
      final snap = sessionManager.currentSnapshot!;
      _progressPercent = snap.progressPercent;
      _speedMbPerSec = snap.speedMbPerSec;
      _bytesTransferred = snap.bytesTransferred;
      _remainingSeconds = snap.remainingSeconds;
      _isPaused = snap.isPaused;
      _isCancelled = snap.isCancelled;
      _batchItems = snap.items;
      _peerContributions = snap.peerChunkContributions;
      _receiverProgressMap.addAll(snap.receiverProgressMap);
      _isPreviewReady = snap.isPreviewReady;
      if (sessionManager.activeCoordinator != null) {
        _activeCoordinator = sessionManager.activeCoordinator;
      }

      if (snap.connectedReceivers.isNotEmpty) {
        _liveReceivers = snap.connectedReceivers;
      }
      _sessionSub = sessionManager.progressStream.listen((snap) {
        if (!mounted) return;
        setState(() {
          _progressPercent = snap.progressPercent;
          _speedMbPerSec = snap.speedMbPerSec;
          _bytesTransferred = snap.bytesTransferred;
          _remainingSeconds = snap.remainingSeconds;
          _isPaused = snap.isPaused;
          _isCancelled = snap.isCancelled;
          _batchItems = snap.items;
          _peerContributions = snap.peerChunkContributions;
          _receiverProgressMap.addAll(snap.receiverProgressMap);
          if (snap.connectedReceivers.isNotEmpty) {
            _liveReceivers = snap.connectedReceivers;
          }
          if (snap.isPreviewReady) {
            _isPreviewReady = true;
          }
        });

        if (snap.isCompleted) {
          _onTransferSuccess();
        } else if (snap.isFailed) {
          _showErrorDialog(snap.errorMessage ?? 'Transfer verification failed.');
        }
      });
    } else if (widget.batchCoordinator != null) {
      _activeCoordinator = widget.batchCoordinator;
      _bindBatchCoordinator(widget.batchCoordinator!);
    } else if (widget.engine != null) {
      _bindTransferEngine(widget.engine!);
    }

    if (widget.isHost) {
      _bindHostControl();
    }
  }

  void _bindBatchCoordinator(BatchTransferCoordinator coordinator) {
    _batchSub = coordinator.progressStream.listen((event) {
      if (!mounted) return;

      final aiService = AIService();
      if (aiService.config.isAiEnabled) {
        aiService.failureDetector.recordChunkSuccess(event.overallSpeedMbPerSec);
        _currentDiagnosis = aiService.failureDetector.diagnose();
      }

      setState(() {
        _batchEvent = event;
        _progressPercent = event.overallProgressPercent;
        _speedMbPerSec = event.overallSpeedMbPerSec;
        _bytesTransferred = event.totalBytesTransferred;
        _isPaused = event.isPaused;
        _isCancelled = event.isCancelled;
      });

      if (event.isCompleted) {
        _onTransferSuccess();
      }
    });
  }

  void _bindTransferEngine(TransferEngine engine) {
    _engineSub = engine.progressStream.listen((event) {
      if (!mounted) return;

      final aiService = AIService();
      if (aiService.config.isAiEnabled) {
        aiService.failureDetector.recordChunkSuccess(event.speedMbPerSec);
        if (!_optimizationApplied) {
          _currentOptimization = aiService.optimizer.recommendOptimization(
            fileSize: _file.sizeBytes,
            currentSpeedMbPerSec: event.speedMbPerSec,
            avgLatencyMillis: 70.0,
            completedChunks: (event.progressPercent * 2).round(),
            retransmissionCount: 0,
            currentWorkers: engine.concurrentWorkers,
          );
        }
        _currentDiagnosis = aiService.failureDetector.diagnose();
      }

      setState(() {
        _progressPercent = event.progressPercent;
        _speedMbPerSec = event.speedMbPerSec;
        _bytesTransferred = event.bytesTransferred;
        _remainingSeconds = event.remainingSeconds;
        _isPaused = event.status == TransferStatus.paused;
        if (event.isPreviewReady) {
          _isPreviewReady = true;
        }
      });

      if (event.status == TransferStatus.completed) {
        _onTransferSuccess();
      } else if (event.status == TransferStatus.failed) {
        if (aiService.config.isAiEnabled) {
          aiService.failureDetector.recordChunkFailure(
            event.errorMessage ?? 'Verification error',
          );
          _currentDiagnosis = aiService.failureDetector.diagnose();
        }
        _showErrorDialog(event.errorMessage ?? 'Transfer verification failed.');
      }
    });
  }

  void _applyRecommendation() {
    if (_currentOptimization == null) return;
    widget.engine?.applyOptimizationSettings(
      maxWorkers: _currentOptimization!.recommendedParallelWorkers,
    );
    setState(() {
      _optimizationApplied = true;
      _currentOptimization!.isApplied = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Optimization Applied: Set to ${_currentOptimization!.recommendedParallelWorkers} workers with ${_currentOptimization!.recommendedChunkSizeLabel} chunks.',
        ),
        backgroundColor: AppColors.primaryBlack,
      ),
    );
  }

  void _bindHostControl() {
    final server = LocalServer();
    if (_liveReceivers.isEmpty && server.connectedReceivers.isNotEmpty) {
      _liveReceivers = server.connectedReceivers;
    }
    _liveReceiversSub ??= server.connectedReceiversStream.listen((list) {
      if (!mounted) return;
      setState(() {
        _liveReceivers = list;
      });
    });
    server.addControlListener(_handleHostControlMessage);
  }

  void _handleHostControlMessage(Map<String, dynamic> msg) {
    if (!mounted) return;
    final type = msg['type'] as String?;
    final peerId = msg['peerId'] as String? ?? 'receiver';

    if (type == 'TRANSFER_PROGRESS') {
      final percent = (msg['percent'] as num?)?.toDouble() ?? 0.0;
      final bytes = (msg['bytesTransferred'] as num?)?.toInt() ?? 0;
      final speed = (msg['speedMbPerSec'] as num?)?.toDouble() ??
          (((msg['speedBytesPerSec'] as num?)?.toDouble() ?? 0.0) / (1024 * 1024));

      setState(() {
        _receiverProgressMap[peerId] = percent;
        if (_receiverProgressMap.isNotEmpty) {
          final avg = _receiverProgressMap.values.reduce((a, b) => a + b) /
              _receiverProgressMap.length;
          _progressPercent = avg;
        }
        if (bytes > _bytesTransferred) {
          _bytesTransferred = bytes;
        }
        if (speed > 0) {
          _speedMbPerSec = speed;
        }
      });
    } else if (type == 'TRANSFER_COMPLETED') {
      setState(() {
        _receiverProgressMap[peerId] = 100.0;
        _progressPercent = 100.0;
      });
      _onTransferSuccess();
    } else if (type == 'RECEIVER_JOINED' || type == 'RECEIVER_READY' || type == 'RECEIVER_FAILED') {
      setState(() {
        _liveReceivers = LocalServer().connectedReceivers;
      });
    }
  }

  void _onTransferSuccess() {
    final totalFiles = _batchEvent?.totalFiles ??
        (widget.batchManifest?.totalFiles ?? 1);

    final transfer = Transfer(
      id: widget.manifest?.fileId ??
          widget.batchManifest?.batchId ??
          'transfer_${DateTime.now().millisecondsSinceEpoch}',
      fileInfo: _file,
      direction:
          widget.isHost ? TransferDirection.sent : TransferDirection.received,
      status: TransferStatus.completed,
      progressPercent: 100.0,
      bytesTransferred: _bytesTransferred > 0 ? _bytesTransferred : _file.sizeBytes,
      transferSpeedMbPerSec: _speedMbPerSec,
      remainingSeconds: 0,
      timestamp: DateTime.now(),
      receivers: _receiverDevices
          .map(
            (d) => ReceiverProgress(
              deviceId: d.id,
              deviceName: d.name,
              progressPercent: 100.0,
            ),
          )
          .toList(),
      chunkStats: {
        'totalFiles': totalFiles,
        'batchId': widget.batchManifest?.batchId,
      },
    );

    TransferRepository().updateTransfer(transfer);

    if (widget.isHost) {
      DiscoveryService().stopRoomHost();
      RoomManager().expireRoom();
      LocalServer().clearBatch();
    }

    if (mounted) {
      _navigateToComplete();
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Transfer Failed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _togglePauseResume() {
    setState(() {
      _isPaused = !_isPaused;
    });

    final sessionManager = TransferSessionManager.instance;
    if (sessionManager.hasActiveSession) {
      if (_isPaused) {
        sessionManager.pause();
      } else {
        sessionManager.resume();
      }
    } else if (_activeCoordinator != null) {
      if (_isPaused) {
        _activeCoordinator!.pause();
      } else {
        _activeCoordinator!.resume();
      }
    } else if (widget.engine != null) {
      if (_isPaused) {
        widget.engine!.pause();
      } else {
        widget.engine!.resume();
      }
    }
  }

  Future<void> _confirmCancel() async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Cancel Transfer?',
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryBlack),
        ),
        content: const Text(
          'Are you sure you want to cancel this transfer? Any partially transferred data will be discarded.',
          style: TextStyle(fontSize: 13, color: AppColors.darkGray),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No, Continue'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
    if (shouldCancel == true) {
      await _cancelTransfer();
    }
  }

  Future<void> _cancelTransfer() async {
    if (_isCancelled) return;
    setState(() {
      _isCancelled = true;
    });

    final sessionManager = TransferSessionManager.instance;
    if (sessionManager.hasActiveSession) {
      await sessionManager.cancel();
    }
    if (_activeCoordinator != null) {
      await _activeCoordinator!.cancel();
    } else if (widget.engine != null) {
      await widget.engine!.cancel();
    }

    if (widget.isHost) {
      DiscoveryService().stopRoomHost();
      RoomManager().expireRoom();
      LocalServer().clearBatch();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transfer cancelled'),
          backgroundColor: AppColors.primaryBlack,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  void _navigateToComplete() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => TransferCompleteScreen(
          fileInfo: _file,
          receiversCount:
              _receiverDevices.isNotEmpty ? _receiverDevices.length : 1,
          avgSpeedText: _speedMbPerSec > 0
              ? '${_speedMbPerSec.toStringAsFixed(1)} MB/s'
              : 'Completed',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _engineSub?.cancel();
    _batchSub?.cancel();
    _liveReceiversSub?.cancel();
    if (widget.isHost) {
      DiscoveryService().stopRoomHost();
      RoomManager().expireRoom();
      LocalServer().clearBatch();
      LocalServer().removeControlListener(_handleHostControlMessage);
    }
    super.dispose();
  }

  String _formatRemainingTime() {
    if (_isPaused) return 'Paused';
    if (_progressPercent >= 100) return '00:00';
    if (_speedMbPerSec <= 0.05 && _remainingSeconds <= 0) return '--:--';
    final mins = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double _getReceiverProgress(int index) {
    if (_receiverDevices.isEmpty) return _progressPercent;
    final device = _receiverDevices[index];
    return _receiverProgressMap[device.id] ?? _progressPercent;
  }

  Widget _buildSessionStatusBadge() {
    final String statusText;
    final Color badgeBg;
    final Color badgeFg;

    if (_isCancelled) {
      statusText = 'Cancelled';
      badgeBg = Colors.grey.shade200;
      badgeFg = AppColors.darkGray;
    } else if (_isPaused) {
      statusText = 'Paused';
      badgeBg = Colors.orange.shade100;
      badgeFg = Colors.orange.shade900;
    } else if (_progressPercent >= 100) {
      statusText = 'Completed';
      badgeBg = Colors.green.shade100;
      badgeFg = Colors.green.shade900;
    } else if (widget.isHost && _liveReceivers.isEmpty && _receiverDevices.isEmpty) {
      statusText = 'Waiting for Receivers';
      badgeBg = Colors.amber.shade100;
      badgeFg = Colors.amber.shade900;
    } else {
      statusText = 'Transferring';
      badgeBg = Colors.blue.shade100;
      badgeFg = Colors.blue.shade900;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: badgeBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        statusText,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: badgeFg,
        ),
      ),
    );
  }

  Widget _buildReceiverStatusPill(ReceiverStatus status) {
    Color bg;
    Color fg;
    switch (status) {
      case ReceiverStatus.joining:
      case ReceiverStatus.connected:
        bg = Colors.blue.shade100;
        fg = Colors.blue.shade900;
        break;
      case ReceiverStatus.ready:
        bg = Colors.green.shade100;
        fg = Colors.green.shade900;
        break;
      case ReceiverStatus.receiving:
        bg = Colors.indigo.shade100;
        fg = Colors.indigo.shade900;
        break;
      case ReceiverStatus.completed:
        bg = Colors.green.shade100;
        fg = Colors.green.shade900;
        break;
      case ReceiverStatus.failed:
        bg = Colors.red.shade100;
        fg = Colors.red.shade900;
        break;
      case ReceiverStatus.disconnected:
        bg = Colors.grey.shade200;
        fg = AppColors.darkGray;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status.displayName,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: fg,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBatch = (_batchEvent != null && _batchEvent!.items.length > 1) ||
        (widget.batchManifest != null && widget.batchManifest!.manifests.length > 1);

    final totalBytes = _batchEvent != null
        ? _batchEvent!.totalBytes
        : (widget.batchManifest?.totalBytes ?? (_file.sizeBytes > 0 ? _file.sizeBytes : 1));

    final currentBytes = _bytesTransferred > 0
        ? _bytesTransferred
        : ((_progressPercent / 100.0) * totalBytes).round();

    final transferredStr = _formatBytes(currentBytes);
    final totalStr = _formatBytes(totalBytes);

    final speedText = _isPaused
        ? '0 MB/s'
        : _speedMbPerSec > 0
            ? '${_speedMbPerSec.toStringAsFixed(1)} MB/s'
            : (_progressPercent >= 100 ? 'Done' : (widget.isHost ? 'Distributing...' : 'Connecting...'));

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.isHost
                    ? (isBatch ? 'Distributing Batch' : 'Distributing File')
                    : (isBatch ? 'Receiving Batch' : 'Receiving File'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _buildSessionStatusBadge(),
          ],
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => Container(
                  padding: const EdgeInsets.all(AppSpacing.s20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.close_rounded),
                        title: const Text('Cancel Transfer'),
                        onTap: () {
                          Navigator.pop(context);
                          _confirmCancel();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
            tooltip: 'More options',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.s20),
                child: Column(
                  children: [
                    if (widget.roomPin != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s16,
                          vertical: AppSpacing.s8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Room PIN: ${widget.roomPin}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2.0,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            if (widget.isHost && LocalServer().isRunning) ...[
                              const SizedBox(height: 4),
                              FutureBuilder<String?>(
                                future: NetworkUtils.getLocalIpAddress(),
                                builder: (context, snapshot) {
                                  final ip = snapshot.data ?? '...';
                                  final port = LocalServer().port;
                                  return Text(
                                    'Direct IP: $ip:$port',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.mediumGray,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s16),
                    ],

                    if (!isBatch) ...[
                      // File details card
                      FileCard(fileInfo: _file),
                      const SizedBox(height: AppSpacing.s24),
                    ] else ...[
                      // Batch Header Summary Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: AppShapes.cardBorderRadius,
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'BATCH TRANSFER (${_batchEvent?.totalFiles ?? widget.batchManifest?.totalFiles ?? 0} FILES)',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                    color: AppColors.mediumGray,
                                  ),
                                ),
                                Text(
                                  totalStr,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlack,
                                  ),
                                ),
                              ],
                            ),
                            if (_batchEvent != null) ...[
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  _buildBatchStatBadge('Done', _batchEvent!.completedFiles, Colors.green),
                                  _buildBatchStatBadge('Active', _batchEvent!.activeFiles, Colors.blue),
                                  _buildBatchStatBadge('Queued', _batchEvent!.queuedFiles, AppColors.mediumGray),
                                  _buildBatchStatBadge('Failed', _batchEvent!.failedFiles, Colors.redAccent),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s20),
                    ],

                    // Main progress display (Large circular indicator)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s16),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 170,
                            height: 170,
                            child: CircularProgressIndicator(
                              value: (_progressPercent / 100.0).clamp(0.0, 1.0),
                              strokeWidth: 10,
                              color: AppColors.primaryBlack,
                              backgroundColor: AppColors.lightGray,
                              strokeCap: StrokeCap.round,
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${_progressPercent.toInt()}%',
                                style: const TextStyle(
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlack,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$transferredStr / $totalStr',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.mediumGray,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s20),

                    // If batch items are present, show the itemized queue
                    () {
                      final displayBatchItems = _batchItems.isNotEmpty
                          ? _batchItems
                          : (_batchEvent?.items ?? []);
                      if (displayBatchItems.isEmpty) return const SizedBox.shrink();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionHeader(title: 'FILES IN BATCH'),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: displayBatchItems.length,
                            itemBuilder: (context, idx) {
                              final item = displayBatchItems[idx];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.backgroundWhite,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.borderGray),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          _getStatusIcon(item.status),
                                          size: 18,
                                          color: _getStatusColor(item.status),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            item.fileInfo.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Text(
                                          '${item.progressPercent.toInt()}%',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                            color: _getStatusColor(item.status),
                                          ),
                                        ),
                                        if (item.status == TransferStatus.failed &&
                                            _activeCoordinator != null) ...[
                                          const SizedBox(width: 8),
                                          IconButton(
                                            icon: const Icon(Icons.refresh_rounded, size: 18),
                                            tooltip: 'Retry File',
                                            onPressed: () => _activeCoordinator!.retryFile(item.fileId),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: (item.progressPercent / 100.0).clamp(0.0, 1.0),
                                        minHeight: 6,
                                        backgroundColor: AppColors.lightGray,
                                        valueColor: AlwaysStoppedAnimation<Color>(_getStatusColor(item.status)),
                                      ),
                                    ),
                                    if (item.errorMessage != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        item.errorMessage!,
                                        style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: AppSpacing.s16),
                        ],
                      );
                    }(),

                    if (_isPreviewReady) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: AppSpacing.s16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s16,
                          vertical: AppSpacing.s10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryBlack,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_circle_outline_rounded,
                              color: AppColors.backgroundWhite,
                              size: 18,
                            ),
                            SizedBox(width: AppSpacing.s8),
                            Text(
                              'PREVIEW READY (First 20% Available)',
                              style: TextStyle(
                                color: AppColors.backgroundWhite,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Real-time statistics grid/row
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.s16),
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.borderGray),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildStatColumn(
                            label: 'Speed',
                            value: speedText,
                            icon: Icons.speed_rounded,
                          ),
                          Container(
                            height: 32,
                            width: 1,
                            color: AppColors.borderGray,
                          ),
                          _buildStatColumn(
                            label: 'Remaining',
                            value: _formatRemainingTime(),
                            icon: Icons.timer_outlined,
                          ),
                          Container(
                            height: 32,
                            width: 1,
                            color: AppColors.borderGray,
                          ),
                          _buildStatColumn(
                            label: 'Receivers',
                            value: '${widget.isHost ? (_liveReceivers.isNotEmpty ? _liveReceivers.where((r) => r.status != ReceiverStatus.disconnected && r.status != ReceiverStatus.failed).length : _receiverDevices.length) : 1}',
                            icon: Icons.devices_rounded,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s16),

                    // AI Transfer Insight & Optimization Card
                    if (AIService().config.isAiEnabled) ...[
                      AITransferInsightCard(
                        optimization: _currentOptimization,
                        diagnosis: _currentDiagnosis,
                        isApplied: _optimizationApplied,
                        onApplyRecommendation: _applyRecommendation,
                      ),
                      const SizedBox(height: AppSpacing.s16),
                    ],

                    // RECEIVER PROGRESS / PEER section
                    if (widget.isHost) ...[
                      const SectionHeader(title: 'CONNECTED RECEIVERS'),
                      if (_liveReceivers.isNotEmpty) ...[
                        Column(
                          children: _liveReceivers.map((receiver) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: AppSpacing.s12),
                              padding: const EdgeInsets.all(AppSpacing.s16),
                              decoration: BoxDecoration(
                                color: AppColors.backgroundWhite,
                                borderRadius: AppShapes.cardBorderRadius,
                                border: Border.all(color: AppColors.borderGray),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            receiver.platform == DevicePlatform.iPhone
                                                ? Icons.phone_iphone_rounded
                                                : Icons.phone_android_rounded,
                                            size: 18,
                                            color: AppColors.primaryBlack,
                                          ),
                                          const SizedBox(width: AppSpacing.s8),
                                          Text(
                                            receiver.deviceName,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.primaryBlack,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildReceiverStatusPill(receiver.status),
                                        ],
                                      ),
                                      Text(
                                        '${receiver.progressPercent.toInt()}%',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primaryBlack,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.s12),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4.0),
                                    child: LinearProgressIndicator(
                                      value: (receiver.progressPercent / 100.0).clamp(0.0, 1.0),
                                      backgroundColor: AppColors.lightGray,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        receiver.status == ReceiverStatus.failed
                                            ? Colors.redAccent
                                            : (receiver.status == ReceiverStatus.completed
                                                ? Colors.green
                                                : AppColors.primaryBlack),
                                      ),
                                      minHeight: 8,
                                    ),
                                  ),
                                  if (receiver.errorMessage != null) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      receiver.errorMessage!,
                                      style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                                    ),
                                  ] else if (receiver.bytesReceived > 0) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      _formatBytes(receiver.bytesReceived),
                                      style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ] else if (_receiverDevices.isNotEmpty) ...[
                        Column(
                          children: List.generate(_receiverDevices.length, (index) {
                            final device = _receiverDevices[index];
                            final progress = _getReceiverProgress(index);
                            return Container(
                              margin: const EdgeInsets.only(bottom: AppSpacing.s12),
                              padding: const EdgeInsets.all(AppSpacing.s16),
                              decoration: BoxDecoration(
                                color: AppColors.backgroundWhite,
                                borderRadius: AppShapes.cardBorderRadius,
                                border: Border.all(color: AppColors.borderGray),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            device.platform == DevicePlatform.iPhone
                                                ? Icons.phone_iphone_rounded
                                                : Icons.phone_android_rounded,
                                            size: 18,
                                            color: AppColors.primaryBlack,
                                          ),
                                          const SizedBox(width: AppSpacing.s8),
                                          Text(
                                            device.name,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.primaryBlack,
                                            ),
                                          ),
                                        ],
                                      ),
                                      Text(
                                        '${progress.toInt()}%',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.primaryBlack,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.s12),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4.0),
                                    child: LinearProgressIndicator(
                                      value: (progress / 100.0).clamp(0.0, 1.0),
                                      backgroundColor: AppColors.lightGray,
                                      valueColor: const AlwaysStoppedAnimation<Color>(
                                        AppColors.primaryBlack,
                                      ),
                                      minHeight: 8,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ] else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(AppSpacing.s16),
                          decoration: BoxDecoration(
                            color: AppColors.lightGray,
                            borderRadius: AppShapes.cardBorderRadius,
                            border: Border.all(color: AppColors.borderGray),
                          ),
                          child: const Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primaryBlack,
                                ),
                              ),
                              SizedBox(width: AppSpacing.s12),
                              Expanded(
                                child: Text(
                                  'Waiting for receivers to join with Room PIN...',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.darkGray,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s16),
                      ],
                    ] else ...[
                      // Receiver Screen: Host Peer Card
                      const SectionHeader(title: 'SENDER CONNECTION'),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundWhite,
                          borderRadius: AppShapes.cardBorderRadius,
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: const BoxDecoration(
                                color: AppColors.primaryBlack,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.hub_rounded,
                                color: AppColors.backgroundWhite,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.roomPin != null
                                        ? 'Host Peer (Room PIN: ${widget.roomPin})'
                                        : 'Host Peer',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _progressPercent >= 100
                                        ? 'Transfer complete & verified'
                                        : (_isPaused ? 'Paused' : 'Downloading verified chunks...'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.mediumGray,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: _progressPercent >= 100
                                    ? Colors.green.shade100
                                    : Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _progressPercent >= 100 ? 'Verified' : 'Connected',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: _progressPercent >= 100
                                      ? Colors.green.shade900
                                      : Colors.blue.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s16),
                    ],
                    if (widget.engine != null) ...[
                      const SizedBox(height: AppSpacing.s16),
                      LiveSwarmVisualization(engine: widget.engine!),
                    ],
                    if (_peerContributions.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.s16),
                      const SectionHeader(title: 'SWARM PEER CONTRIBUTIONS'),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        decoration: BoxDecoration(
                          color: AppColors.backgroundWhite,
                          borderRadius: AppShapes.cardBorderRadius,
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: Column(
                          children: _peerContributions.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.hub_rounded, size: 16, color: AppColors.mediumGray),
                                      const SizedBox(width: 8),
                                      Text(
                                        entry.key.length > 12
                                            ? '${entry.key.substring(0, 10)}...'
                                            : entry.key,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '${entry.value} chunks',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Interactive Control Buttons
            Container(
              padding: const EdgeInsets.all(AppSpacing.s16),
              decoration: const BoxDecoration(
                color: AppColors.backgroundWhite,
                border: Border(
                  top: BorderSide(color: AppColors.borderGray, width: 1.0),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _isPaused
                        ? PrimaryButton(
                            text: 'RESUME',
                            icon: Icons.play_arrow_rounded,
                            onPressed: _togglePauseResume,
                          )
                        : SecondaryButton(
                            text: 'PAUSE',
                            icon: Icons.pause_rounded,
                            onPressed: _togglePauseResume,
                          ),
                  ),
                  const SizedBox(width: AppSpacing.s12),
                  Expanded(
                    child: SecondaryButton(
                      text: 'CANCEL',
                      icon: Icons.close_rounded,
                      onPressed: _confirmCancel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchStatBadge(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.mediumGray,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  IconData _getStatusIcon(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return Icons.check_circle_rounded;
      case TransferStatus.transferring:
      case TransferStatus.starting:
        return Icons.arrow_circle_down_rounded;
      case TransferStatus.paused:
        return Icons.pause_circle_rounded;
      case TransferStatus.failed:
        return Icons.error_rounded;
      case TransferStatus.cancelled:
        return Icons.cancel_rounded;
    }
  }

  Color _getStatusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.transferring:
      case TransferStatus.starting:
        return AppColors.primaryBlack;
      case TransferStatus.paused:
        return Colors.orangeAccent;
      case TransferStatus.failed:
        return Colors.redAccent;
      case TransferStatus.cancelled:
        return AppColors.mediumGray;
    }
  }

  Widget _buildStatColumn({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AppColors.darkGray),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGray,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
      ],
    );
  }
}
