import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../ai/ai_models.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../../models/models.dart';
import '../../network/local_server.dart';
import '../../repositories/transfer_repository.dart';
import '../../transfer/transfer_engine.dart';
import '../../widgets/widgets.dart';
import 'transfer_complete_screen.dart';

class TransferProgressScreen extends StatefulWidget {
  final FileInfo? fileInfo;
  final List<Device>? receivers;
  final TransferEngine? engine;
  final File? destinationFile;
  final File? sourceFile;
  final Manifest? manifest;
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

  StreamSubscription<TransferProgressEvent>? _engineSub;
  final Map<String, double> _receiverProgressMap = {};

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

    if (widget.engine != null) {
      _bindTransferEngine(widget.engine!);
    } else if (widget.isHost) {
      _bindHostControl();
    }
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
      });

      if (event.status == TransferStatus.completed) {
        _onTransferSuccess();
      } else if (event.status == TransferStatus.failed) {
        if (aiService.config.isAiEnabled) {
          aiService.failureDetector.recordChunkFailure(event.errorMessage ?? 'Verification error');
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
    server.addControlListener(_handleHostControlMessage);
  }

  void _handleHostControlMessage(Map<String, dynamic> msg) {
    if (!mounted) return;
    final type = msg['type'] as String?;
    final peerId = msg['peerId'] as String? ?? 'receiver';

    if (type == 'TRANSFER_PROGRESS') {
      final percent = (msg['percent'] as num?)?.toDouble() ?? 0.0;
      setState(() {
        _receiverProgressMap[peerId] = percent;
        if (_receiverProgressMap.isNotEmpty) {
          final avg = _receiverProgressMap.values.reduce((a, b) => a + b) /
              _receiverProgressMap.length;
          _progressPercent = avg;
        }
      });
    } else if (type == 'TRANSFER_COMPLETED') {
      setState(() {
        _receiverProgressMap[peerId] = 100.0;
        _progressPercent = 100.0;
      });
      _onTransferSuccess();
    }
  }

  void _onTransferSuccess() {
    final transfer = Transfer(
      id: widget.manifest?.fileId ?? 'transfer_${DateTime.now().millisecondsSinceEpoch}',
      fileInfo: _file,
      direction: widget.isHost ? TransferDirection.sent : TransferDirection.received,
      status: TransferStatus.completed,
      progressPercent: 100.0,
      bytesTransferred: _file.sizeBytes,
      transferSpeedMbPerSec: _speedMbPerSec,
      remainingSeconds: 0,
      timestamp: DateTime.now(),
      receivers: _receiverDevices
          .map(
            (d) => ReceiverProgress(
              deviceId: d.id,
              deviceName: d.name,
              progressPercent: 100.0,
              isCompleted: true,
            ),
          )
          .toList(),
      chunkStats: {
        'chunkCount': widget.manifest?.chunkCount ?? 0,
        'chunkSize': widget.manifest?.chunkSize ?? 0,
      },
    );

    TransferRepository().updateTransfer(transfer);
    _navigateToComplete();
  }

  void _showErrorDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
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

    if (widget.engine != null) {
      if (_isPaused) {
        widget.engine!.pause();
      } else {
        widget.engine!.resume();
      }
    }
  }

  Future<void> _cancelTransfer() async {
    setState(() {
      _isCancelled = true;
    });

    if (widget.engine != null) {
      await widget.engine!.cancel();
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
          receiversCount: _receiverDevices.isNotEmpty ? _receiverDevices.length : 1,
          avgSpeedText: _speedMbPerSec > 0
              ? '${_speedMbPerSec.toStringAsFixed(1)} MB/s'
              : 'Completed',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _engineSub?.cancel();
    if (widget.isHost) {
      LocalServer().removeControlListener(_handleHostControlMessage);
    }
    super.dispose();
  }

  String _formatRemainingTime() {
    if (_isPaused) return 'Paused';
    if (_progressPercent >= 100) return '00:00';
    final mins = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double _getReceiverProgress(int index) {
    if (_receiverDevices.isEmpty) return _progressPercent;
    final device = _receiverDevices[index];
    return _receiverProgressMap[device.id] ?? _progressPercent;
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _file.sizeBytes > 0 ? _file.sizeBytes : 1;
    final currentBytes = _bytesTransferred > 0
        ? _bytesTransferred
        : ((_progressPercent / 100.0) * totalBytes).round();

    final transferredStr = _formatBytes(currentBytes);
    final totalStr = _file.formattedSize.isNotEmpty
        ? _file.formattedSize
        : _formatBytes(totalBytes);

    final speedText = _isPaused
        ? '0 MB/s'
        : _speedMbPerSec > 0
            ? '${_speedMbPerSec.toStringAsFixed(1)} MB/s'
            : (_progressPercent >= 100 ? 'Done' : 'Connecting...');

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: Text(widget.isHost ? 'Distributing File...' : 'Receiving File...'),
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
                          _cancelTransfer();
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
                        child: Text(
                          'Room PIN: ${widget.roomPin}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2.0,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s16),
                    ],

                    // File details card
                    FileCard(fileInfo: _file),
                    const SizedBox(height: AppSpacing.s24),

                    // Main progress display (Large circular indicator)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s24),
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
                    const SizedBox(height: AppSpacing.s24),

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
                            value: '${_receiverDevices.length}',
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

                    // RECEIVER PROGRESS section
                    if (_receiverDevices.isNotEmpty) ...[
                      const SectionHeader(title: 'RECEIVER PROGRESS'),
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
                      onPressed: _cancelTransfer,
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
