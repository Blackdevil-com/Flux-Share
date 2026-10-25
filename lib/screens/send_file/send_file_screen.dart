import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/theme.dart';
import '../../discovery/discovery_service.dart';
import '../../file/file_picker_service.dart';
import '../../file/manifest_service.dart';
import '../../models/batch_manifest.dart';
import '../../models/device.dart';
import '../../models/file_info.dart';
import '../../models/manifest.dart';
import '../../network/local_server.dart';
import '../../network/network_utils.dart';
import '../../repositories/device_repository.dart';
import '../../room/room_manager.dart';
import '../../transfer/transfer_session_manager.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_progress_screen.dart';

enum FilePreparationStatus {
  selected,
  queued,
  preparing,
  hashing,
  ready,
  manifestReady,
  hostingReady,
  error,
  cancelled;

  bool get isManifestReady =>
      this == FilePreparationStatus.ready ||
      this == FilePreparationStatus.manifestReady ||
      this == FilePreparationStatus.hostingReady;
}

class PickedFileItem {
  final String id;
  int jobId;
  File file;
  FileInfo info;
  FilePreparationStatus status;
  Manifest? manifest;
  ManifestProgress? progress;
  String? errorMessage;
  bool isCancelled;
  final ValueNotifier<ManifestProgress?> progressNotifier;

  PickedFileItem({
    required this.id,
    this.jobId = 1,
    required this.file,
    required this.info,
    this.status = FilePreparationStatus.selected,
    this.manifest,
    this.progress,
    this.errorMessage,
    this.isCancelled = false,
  }) : progressNotifier = ValueNotifier<ManifestProgress?>(progress);

  bool get isReady => status.isManifestReady && manifest != null;

  SelectedFilePayload toPayload() {
    return SelectedFilePayload(
      file: file,
      name: info.name,
      sizeBytes: info.sizeBytes,
      extension: info.extension,
      type: info.type,
    );
  }
}

class _StagedFileItem {
  final SelectedFilePayload payload;
  final bool isExisting;
  final PickedFileItem? originalItem;
  bool isSelected;

  _StagedFileItem({
    required this.payload,
    required this.isExisting,
    this.originalItem,
    this.isSelected = true,
  });
}

class SendFileScreen extends StatefulWidget {
  final FileInfo? initialFile;
  final String? initialDeviceId;
  final List<PickedFileItem>? initialPickedItems;
  final Manifest? initialManifest;

  const SendFileScreen({
    super.key,
    this.initialFile,
    this.initialDeviceId,
    this.initialPickedItems,
    this.initialManifest,
  });

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  final DeviceRepository _deviceRepository = DeviceRepository();
  final DiscoveryService _discoveryService = DiscoveryService();
  final List<PickedFileItem> _selectedFiles = [];
  final Set<int> _activeWorkerJobIds = {};
  static const int _maxConcurrentWorkers = 2;
  final Set<String> _selectedDeviceIds = {};
  final ValueNotifier<int> _manifestUpdateNotifier = ValueNotifier<int>(0);
  List<Device> _nearbyDevices = [];
  bool _isLoadingDevices = true;
  late String _roomPin;
  String _hostAddress = '';

  @override
  void initState() {
    super.initState();
    _generateRoomPin();
    if (widget.initialPickedItems != null && widget.initialPickedItems!.isNotEmpty) {
      _selectedFiles.addAll(widget.initialPickedItems!);
      _startPreparationQueue();
    } else if (widget.initialFile != null) {
      final file = File(widget.initialFile!.id);
      _selectedFiles.add(
        PickedFileItem(
          id: widget.initialFile!.id,
          jobId: 1,
          file: file,
          info: widget.initialFile!,
          status: widget.initialManifest != null
              ? FilePreparationStatus.manifestReady
              : FilePreparationStatus.selected,
          manifest: widget.initialManifest,
        ),
      );
      if (widget.initialManifest == null) {
        _startPreparationQueue();
      }
    }
    if (widget.initialDeviceId != null) {
      _selectedDeviceIds.add(widget.initialDeviceId!);
    }
    _loadDevices();
  }

  @override
  void dispose() {
    for (final item in _selectedFiles) {
      item.isCancelled = true;
      item.jobId++;
      item.progressNotifier.dispose();
    }
    _manifestUpdateNotifier.dispose();
    super.dispose();
  }

  void _generateRoomPin() {
    _roomPin = (1000 + Random().nextInt(9000)).toString();
  }

  Future<void> _loadDevices() async {
    final devices = await _deviceRepository.getNearbyDevices();
    final ip = await NetworkUtils.getLocalIpAddress();
    if (mounted) {
      setState(() {
        _nearbyDevices = devices;
        _isLoadingDevices = false;
        _hostAddress = ip ?? '';
      });
    }
  }

  int get _totalSelectedBytes =>
      _selectedFiles.fold(0, (sum, item) => sum + item.info.sizeBytes);

  int get _readyCount =>
      _selectedFiles.where((i) => i.status == FilePreparationStatus.manifestReady).length;

  int get _preparingCount => _selectedFiles
      .where((i) =>
          i.status == FilePreparationStatus.preparing ||
          i.status == FilePreparationStatus.hashing)
      .length;

  int get _queuedCount => _selectedFiles
      .where((i) =>
          i.status == FilePreparationStatus.selected ||
          i.status == FilePreparationStatus.queued)
      .length;

  String get _formattedTotalBytes {
    final bytes = _totalSelectedBytes;
    if (bytes <= 0 && _selectedFiles.isNotEmpty) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  bool get _canStartTransfer {
    if (_selectedFiles.isEmpty) return false;
    return _selectedFiles.every((i) => i.isReady);
  }

  String get _transferButtonText {
    if (_selectedFiles.isEmpty) {
      return 'SELECT FILE TO SHARE';
    }
    final total = _selectedFiles.length;
    final ready = _readyCount;
    if (_canStartTransfer) {
      return total > 1 ? 'START BATCH TRANSFER ($total)' : 'START TRANSFER';
    }
    final hasError = _selectedFiles.any((i) => i.status == FilePreparationStatus.error);
    if (hasError) {
      return 'RESOLVE ERRORS BEFORE TRANSFER';
    }
    final hasCancelled = _selectedFiles.any((i) => i.status == FilePreparationStatus.cancelled);
    if (hasCancelled) {
      return 'PREPARATION INCOMPLETE';
    }
    return 'PREPARING MANIFESTS ($ready/$total READY)';
  }

  /// Opens the native multi-file picker to add more files to the selection.
  Future<void> _openFileBrowser() async {
    try {
      final payloads = await FilePickerService.pickMultipleFilePayloads();
      if (payloads.isEmpty) {
        debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');
        return;
      }

      int addedCount = 0;
      for (final payload in payloads) {
        final path = payload.file.path;
        final existingIndex = _selectedFiles.indexWhere((item) =>
            item.file.path == path ||
            (item.info.name == payload.name && item.info.sizeBytes == payload.sizeBytes));

        if (existingIndex != -1) {
          final existing = _selectedFiles[existingIndex];
          if (existing.status == FilePreparationStatus.cancelled ||
              existing.status == FilePreparationStatus.error) {
            existing.isCancelled = false;
            existing.errorMessage = null;
            existing.progress = null;
            existing.jobId++;
            existing.status = FilePreparationStatus.selected;
            addedCount++;
            debugPrint('[FluxShare-Diag] [B1:Select] Re-selected existing cancelled/error file: jobId=${existing.jobId}, file=${existing.info.name}');
          }
          continue;
        }

        final item = PickedFileItem(
          id: '${payload.file.path}_${DateTime.now().microsecondsSinceEpoch}',
          jobId: 1,
          file: payload.file,
          info: payload.toFileInfo(),
          status: FilePreparationStatus.selected,
        );
        _selectedFiles.add(item);
        addedCount++;
        debugPrint('[FluxShare-Diag] [B1:Select] jobId=${item.jobId}, file=${item.info.name}, size=${item.info.sizeBytes}');
      }

      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');

      if (mounted) {
        setState(() {});
        _manifestUpdateNotifier.value++;
        if (addedCount == 0 && payloads.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selected files are already in the transfer list.'),
              backgroundColor: AppColors.primaryBlack,
            ),
          );
        }
      }

      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      _startPreparationQueue();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not access files: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  /// Change selection flow:
  /// Opens native picker, merges with existing selection in a staging review dialog,
  /// preserves valid manifests for unchanged files, and applies confirmed changes.
  Future<void> _openChangeFlow() async {
    try {
      final newPayloads = await FilePickerService.pickMultipleFilePayloads();
      if (newPayloads.isEmpty) {
        debugPrint('[FluxShare] Change flow cancelled by user; retaining existing selection.');
        return;
      }

      // Build staged items combining existing selection and newly picked files
      final List<_StagedFileItem> stagedList = [];

      for (final item in _selectedFiles) {
        stagedList.add(_StagedFileItem(
          payload: item.toPayload(),
          isExisting: true,
          originalItem: item,
          isSelected: true,
        ));
      }

      for (final payload in newPayloads) {
        final isDup = stagedList.any((staged) =>
            staged.payload.file.path == payload.file.path ||
            (staged.payload.name == payload.name &&
                staged.payload.sizeBytes == payload.sizeBytes));
        if (!isDup) {
          stagedList.add(_StagedFileItem(
            payload: payload,
            isExisting: false,
            isSelected: true,
          ));
        }
      }

      if (!mounted) return;
      await _showChangeReviewSheet(stagedList);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not change files: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  Future<void> _showChangeReviewSheet(List<_StagedFileItem> stagedList) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final activeCount = stagedList.where((i) => i.isSelected).length;
            final activeBytes = stagedList
                .where((i) => i.isSelected)
                .fold<int>(0, (sum, i) => sum + i.payload.sizeBytes);

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              decoration: const BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag Handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderGray,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Review Selection',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$activeCount ${activeCount == 1 ? 'file' : 'files'} · ${FileInfo.formatBytes(activeBytes)} total',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.mediumGray,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.borderGray),

                  // File List
                  Flexible(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shrinkWrap: true,
                      itemCount: stagedList.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, idx) {
                        final item = stagedList[idx];
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: item.isSelected
                                ? AppColors.backgroundWhite
                                : AppColors.lightGray.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: item.isSelected
                                  ? AppColors.borderGray
                                  : AppColors.borderGray.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: AppColors.lightGray,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  _getFileIcon(item.payload.type, item.payload.extension),
                                  size: 18,
                                  color: _getFileIconColor(item.payload.type, item.payload.extension),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.payload.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: item.isSelected
                                            ? AppColors.primaryBlack
                                            : AppColors.mediumGray,
                                        decoration: item.isSelected
                                            ? null
                                            : TextDecoration.lineThrough,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Text(
                                          FileInfo.formatBytes(item.payload.sizeBytes),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.mediumGray,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: item.isExisting
                                                ? AppColors.lightGray
                                                : AppColors.primaryBlack,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            item.isExisting ? 'Previously selected' : 'Newly added',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: item.isExisting
                                                  ? AppColors.primaryBlack
                                                  : Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  item.isSelected
                                      ? Icons.remove_circle_outline_rounded
                                      : Icons.add_circle_outline_rounded,
                                  color: item.isSelected ? Colors.redAccent : Colors.green,
                                  size: 20,
                                ),
                                tooltip: item.isSelected ? 'Remove' : 'Re-include',
                                onPressed: () {
                                  setModalState(() {
                                    item.isSelected = !item.isSelected;
                                  });
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                  // Actions
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: AppColors.borderGray)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SecondaryButton(
                            text: 'CANCEL',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: PrimaryButton(
                            text: 'CONFIRM (${stagedList.where((i) => i.isSelected).length})',
                            onPressed: () {
                              Navigator.of(context).pop();
                              _applyConfirmedStagedSelection(stagedList);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _applyConfirmedStagedSelection(List<_StagedFileItem> stagedList) {
    final confirmed = stagedList.where((i) => i.isSelected).toList();

    // 1. Identify removed files: cancel their ongoing tasks
    final confirmedExisting = confirmed.where((i) => i.isExisting).map((i) => i.originalItem!).toSet();
    for (final item in List<PickedFileItem>.from(_selectedFiles)) {
      if (!confirmedExisting.contains(item)) {
        debugPrint('[FluxShare-Diag] [B8:CancelReq] jobId=${item.jobId}, file=${item.info.name}, reason=removed_in_change_review');
        item.isCancelled = true;
        item.jobId++;
        item.progressNotifier.dispose();
        _selectedFiles.remove(item);
      }
    }

    // 2. Identify newly added files: append to _selectedFiles
    int newlyAddedCount = 0;
    for (final item in confirmed.where((i) => !i.isExisting)) {
      final existingIndex = _selectedFiles.indexWhere((existing) =>
          existing.file.path == item.payload.file.path ||
          (existing.info.name == item.payload.name &&
              existing.info.sizeBytes == item.payload.sizeBytes));

      if (existingIndex != -1) {
        final existing = _selectedFiles[existingIndex];
        if (existing.status == FilePreparationStatus.cancelled ||
            existing.status == FilePreparationStatus.error) {
          existing.isCancelled = false;
          existing.status = FilePreparationStatus.selected;
          existing.errorMessage = null;
          existing.progress = null;
          existing.jobId++;
          newlyAddedCount++;
          debugPrint('[FluxShare-Diag] [B1:Select] Re-selected cancelled/error file in change review: jobId=${existing.jobId}, file=${existing.info.name}');
        }
        continue;
      }

      final newItem = PickedFileItem(
        id: '${item.payload.file.path}_${DateTime.now().microsecondsSinceEpoch}',
        jobId: 1,
        file: item.payload.file,
        info: item.payload.toFileInfo(),
        status: FilePreparationStatus.selected,
      );
      _selectedFiles.add(newItem);
      newlyAddedCount++;
      debugPrint('[FluxShare-Diag] [B1:Select] jobId=${newItem.jobId}, file=${newItem.info.name}, size=${newItem.info.sizeBytes}');
    }

    if (mounted) {
      setState(() {});
      _manifestUpdateNotifier.value++;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Selection updated: ${_selectedFiles.length} files selected ($newlyAddedCount added).',
          ),
          backgroundColor: AppColors.primaryBlack,
        ),
      );
    }

    Future.microtask(() {
      if (mounted) _startPreparationQueue();
    });
  }

  void _confirmClearAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all files?'),
        content: const Text('This will remove all selected files and cancel pending manifest preparation.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              _clearAllFiles();
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  void _clearAllFiles() {
    for (final item in _selectedFiles) {
      debugPrint('[FluxShare-Diag] [B8:CancelReq] jobId=${item.jobId}, file=${item.info.name}, reason=clear_all');
      item.isCancelled = true;
      item.jobId++;
      item.progressNotifier.dispose();
    }
    setState(() {
      _selectedFiles.clear();
    });
    _manifestUpdateNotifier.value++;
    debugPrint('[FluxShare] Selection state contains: 0 files');
    _runPreparationWorkers();
  }

  void _removeFileAt(int index) {
    if (index >= 0 && index < _selectedFiles.length) {
      final removed = _selectedFiles[index];
      debugPrint('[FluxShare-Diag] [B8:CancelReq] jobId=${removed.jobId}, file=${removed.info.name}, reason=file_removed');
      removed.isCancelled = true;
      removed.jobId++;
      removed.progressNotifier.dispose();
      setState(() {
        _selectedFiles.removeAt(index);
      });
      _manifestUpdateNotifier.value++;
      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');
      _runPreparationWorkers();
    }
  }

  void _cancelPreparation(PickedFileItem item) {
    debugPrint('[FluxShare-Diag] [B8:CancelReq] jobId=${item.jobId}, file=${item.info.name}, reason=user_cancelled');
    item.isCancelled = true;
    item.jobId++;
    setState(() {
      item.status = FilePreparationStatus.cancelled;
      item.progress = null;
      item.errorMessage = null;
    });
    item.progressNotifier.value = null;
    _manifestUpdateNotifier.value++;
    debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=${item.jobId}, file=${item.info.name}, from=hashing, to=cancelled');
    _runPreparationWorkers();
  }

  void _retryPreparation(PickedFileItem item) {
    debugPrint('[FluxShare-Diag] [B1:Select] retry jobId=${item.jobId + 1}, file=${item.info.name}');
    item.isCancelled = false;
    item.status = FilePreparationStatus.selected;
    item.errorMessage = null;
    item.progress = null;
    item.jobId++;
    setState(() {});
    _manifestUpdateNotifier.value++;
    _startPreparationQueue();
  }

  /// Incremental asynchronous preparation queue.
  /// Runs up to 2 file hashing workers concurrently in background isolates,
  /// ensuring smaller files finish immediately without waiting for a 3.5 GB video.
  void _startPreparationQueue() {
    final pending = _selectedFiles.where((i) => i.status == FilePreparationStatus.selected).toList();
    for (final item in pending) {
      item.status = FilePreparationStatus.queued;
      debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=${item.jobId}, file=${item.info.name}, from=selected, to=queued');
    }
    debugPrint('[FluxShare-Diag] [B2:Scheduler] queueInvoked: pendingSelected=${pending.length}, totalSelectedFiles=${_selectedFiles.length}');
    _runPreparationWorkers();
  }

  void _runPreparationWorkers() {
    if (!mounted) return;

    final queuedItems = _selectedFiles
        .where((i) => i.status == FilePreparationStatus.queued)
        .toList();

    final beforeActive = _activeWorkerJobIds.length;
    final availableSlots = (_maxConcurrentWorkers - beforeActive).clamp(0, _maxConcurrentWorkers);

    debugPrint('[FluxShare-Diag] [B2:Scheduler] runWorkers: activeWorkers=$beforeActive, queued=${queuedItems.length}, availableSlots=$availableSlots');

    int admittedCount = 0;
    for (int i = 0; i < availableSlots && i < queuedItems.length; i++) {
      final item = queuedItems[i];
      // Mark as preparing immediately to prevent re-admission in case of re-entrant scheduler calls
      item.status = FilePreparationStatus.preparing;
      _activeWorkerJobIds.add(item.jobId);
      admittedCount++;

      debugPrint('[FluxShare-Diag] [B3:Admission] admitting jobId=${item.jobId}, file=${item.info.name}');

      _processItem(item).whenComplete(() {
        if (mounted) {
          _runPreparationWorkers();
        }
      });
    }

    final afterActive = _activeWorkerJobIds.length;
    debugPrint('[FluxShare-Diag] [B3:Admission] beforeActive=$beforeActive, admitted=$admittedCount, afterActive=$afterActive, availableSlots=$availableSlots');
  }

  Future<void> _processItem(PickedFileItem targetItem) async {
    final int activeJobId = targetItem.jobId;
    String outcome = 'unknown';

    debugPrint('[FluxShare-Diag] [B4:ProcessItem] entering: jobId=$activeJobId, file=${targetItem.info.name}');

    try {
      if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
        setState(() {
          targetItem.status = FilePreparationStatus.preparing;
        });
        _manifestUpdateNotifier.value++;
      }

      if (targetItem.isCancelled || targetItem.jobId != activeJobId) {
        outcome = 'cancelled_before_start';
        return;
      }

      if (!await targetItem.file.exists()) {
        outcome = 'error_file_not_found';
        if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
          setState(() {
            targetItem.status = FilePreparationStatus.error;
            targetItem.errorMessage = 'File not found on disk';
          });
          _manifestUpdateNotifier.value++;
        }
        return;
      }

      if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
        setState(() {
          targetItem.status = FilePreparationStatus.hashing;
        });
        _manifestUpdateNotifier.value++;
        debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=$activeJobId, file=${targetItem.info.name}, from=preparing, to=hashing');
      }

      final manifest = await ManifestService.generateManifest(
        targetItem.file,
        fileId: targetItem.id,
        onProgress: (p) {
          if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
            targetItem.progress = p;
            targetItem.progressNotifier.value = p;
          }
        },
        isCancelled: () =>
            !mounted || targetItem.jobId != activeJobId || targetItem.isCancelled,
      );

      if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
        outcome = 'success';
        setState(() {
          targetItem.manifest = manifest;
          targetItem.status = FilePreparationStatus.manifestReady;
          targetItem.errorMessage = null;
        });
        _manifestUpdateNotifier.value++;
        debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=$activeJobId, file=${targetItem.info.name}, from=hashing, to=manifestReady');
      } else {
        outcome = 'cancelled_on_completion';
      }
    } catch (e) {
      if (targetItem.isCancelled || (e is FormatException && e.message.contains('cancelled'))) {
        outcome = 'cancelled';
        debugPrint('[FluxShare-Diag] [B8:CancelAck] caught cancellation for jobId=$activeJobId, file=${targetItem.info.name}');
        if (mounted) {
          setState(() {
            targetItem.status = FilePreparationStatus.cancelled;
            targetItem.progress = null;
          });
          _manifestUpdateNotifier.value++;
          debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=$activeJobId, file=${targetItem.info.name}, to=cancelled');
        }
      } else {
        outcome = 'error: $e';
        debugPrint('[FluxShare-Diag] [B9:StateTransition] jobId=$activeJobId, file=${targetItem.info.name}, error: $e');
        if (mounted && targetItem.jobId == activeJobId) {
          setState(() {
            targetItem.status = FilePreparationStatus.error;
            targetItem.errorMessage = e.toString();
          });
          _manifestUpdateNotifier.value++;
        }
      }
    } finally {
      // CRITICAL: Always release worker slot regardless of how _processItem exits
      _activeWorkerJobIds.remove(activeJobId);
      debugPrint('[FluxShare-Diag] [B9:StateTransition] workerSlotReleased: jobId=$activeJobId, file=${targetItem.info.name}, remainingWorkers=${_activeWorkerJobIds.length}');
      debugPrint('[FluxShare-Diag] [B10:SchedulerReinvoked] trigger=$outcome, file=${targetItem.info.name}, jobId=$activeJobId');
    }
  }

  void _toggleDeviceSelection(String deviceId) {
    setState(() {
      if (_selectedDeviceIds.contains(deviceId)) {
        _selectedDeviceIds.remove(deviceId);
      } else {
        _selectedDeviceIds.add(deviceId);
      }
    });
  }

  IconData _getFileIcon(FileType type, String ext) {
    final lowerExt = ext.toLowerCase();
    if (lowerExt == 'pdf') {
      return Icons.picture_as_pdf_rounded;
    }
    if (['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'].contains(lowerExt)) {
      return Icons.audiotrack_rounded;
    }
    switch (type) {
      case FileType.Video:
        return Icons.videocam_rounded;
      case FileType.Document:
        return Icons.description_rounded;
      case FileType.Archive:
        return Icons.folder_zip_rounded;
      case FileType.Presentation:
        return Icons.slideshow_rounded;
      case FileType.Image:
        return Icons.image_rounded;
      case FileType.Other:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getFileIconColor(FileType type, String ext) {
    final lowerExt = ext.toLowerCase();
    if (lowerExt == 'pdf') {
      return Colors.red.shade700;
    }
    if (['mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'].contains(lowerExt)) {
      return Colors.purple.shade700;
    }
    switch (type) {
      case FileType.Video:
        return Colors.blue.shade700;
      case FileType.Image:
        return Colors.teal.shade700;
      case FileType.Archive:
        return Colors.amber.shade800;
      case FileType.Presentation:
        return Colors.deepOrange.shade700;
      case FileType.Document:
        return Colors.indigo.shade700;
      case FileType.Other:
        return AppColors.primaryBlack;
    }
  }

  Future<void> _startTransfer() async {
    debugPrint('[FluxShare] Start Transfer received: ${_selectedFiles.length} files');
    if (!_canStartTransfer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please wait for all file manifests to finish preparing')),
      );
      return;
    }

    try {
      for (final item in _selectedFiles) {
        item.status = FilePreparationStatus.hostingReady;
      }
      _manifestUpdateNotifier.value++;

      final List<Manifest> manifests = _selectedFiles.map((i) => i.manifest!).toList();
      final List<({Manifest manifest, File file})> batchItems =
          _selectedFiles.map((i) => (manifest: i.manifest!, file: i.file)).toList();

      final batchManifest = BatchManifest(
        batchId: 'batch_${DateTime.now().millisecondsSinceEpoch}',
        manifests: manifests,
      );

      final server = LocalServer();
      final port = await server.start();
      server.setBatchManifests(batchItems);

      await _discoveryService.startRoomHost(
        pin: _roomPin,
        roomId: batchManifest.batchId,
        serverPort: port,
        deviceName: server.localDeviceName,
      );

      RoomManager().createRoom(
        hostPeerId: server.localPeerId,
        hostDeviceName: server.localDeviceName,
        customPin: _roomPin,
        manifest: manifests.first,
        batchManifest: batchManifest,
      );

      final selectedDevices = _nearbyDevices
          .where((d) => _selectedDeviceIds.contains(d.id))
          .toList();

      await TransferSessionManager.instance.startHostSession(
        server: server,
        batchManifest: batchManifest,
        receivers: selectedDevices,
        roomPin: _roomPin,
      );

      if (mounted) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => TransferProgressScreen(
              batchManifest: batchManifest,
              sourceFiles: _selectedFiles.map((i) => i.file).toList(),
              fileInfo: _selectedFiles.first.info,
              sourceFile: _selectedFiles.first.file,
              manifest: manifests.first,
              isHost: true,
              roomPin: _roomPin,
              receivers: selectedDevices,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error preparing transfer: $e')),
        );
      }
    }
  }

  void _openConnectedDevicesSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.75,
              ),
              decoration: const BoxDecoration(
                color: AppColors.backgroundWhite,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderGray,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Connected Devices',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _selectedDeviceIds.isNotEmpty
                                    ? Colors.green.shade100
                                    : AppColors.lightGray,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_selectedDeviceIds.length}/${_nearbyDevices.length} selected',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: _selectedDeviceIds.isNotEmpty
                                      ? Colors.green.shade800
                                      : AppColors.mediumGray,
                                ),
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.borderGray),

                  // Device list or empty state
                  Flexible(
                    child: _isLoadingDevices
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: CircularProgressIndicator(color: AppColors.primaryBlack),
                            ),
                          )
                        : _nearbyDevices.isEmpty
                            ? Container(
                                padding: const EdgeInsets.all(32),
                                alignment: Alignment.center,
                                child: const Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.radar_rounded,
                                      size: 48,
                                      color: AppColors.mediumGray,
                                    ),
                                    SizedBox(height: 12),
                                    Text(
                                      'No devices connected yet',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryBlack,
                                      ),
                                    ),
                                    SizedBox(height: 6),
                                    Text(
                                      'Nearby receivers can join using the Room PIN or auto-discover this hotspot.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.mediumGray,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                shrinkWrap: true,
                                itemCount: _nearbyDevices.length,
                                itemBuilder: (context, index) {
                                  final device = _nearbyDevices[index];
                                  final isSelected = _selectedDeviceIds.contains(device.id);
                                  return DeviceListItem(
                                    device: device,
                                    isSelected: isSelected,
                                    onSelectedChanged: (val) {
                                      _toggleDeviceSelection(device.id);
                                      setSheetState(() {});
                                    },
                                  );
                                },
                              ),
                  ),

                  // Bottom action
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: PrimaryButton(
                      text: 'DONE',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSelectionSummaryBar() {
    if (_selectedFiles.isEmpty) {
      return FilePickerCard(
        onTap: _openFileBrowser,
        title: 'Select Files to Share',
        subtitle: 'Tap to select files. Large files hash in background with live progress.',
      );
    }

    final totalCount = _selectedFiles.length;
    final totalSizeStr = _formattedTotalBytes;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.lightGray,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderGray),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              '$totalCount ${totalCount == 1 ? 'file' : 'files'} selected · $totalSizeStr total',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: AppColors.primaryBlack,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: _openChangeFlow,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryBlack,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('Change'),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                onPressed: _openFileBrowser,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primaryBlack,
                  side: const BorderSide(color: AppColors.borderGray),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('Add More'),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                tooltip: 'Clear All',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _confirmClearAll,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRoomPinCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.primaryBlack,
        borderRadius: AppShapes.cardBorderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ROOM PIN FOR RECEIVERS',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'ROOM PIN: $_roomPin',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, color: Colors.white),
                tooltip: 'Copy PIN',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _roomPin));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Room PIN $_roomPin copied to clipboard!'),
                      duration: const Duration(seconds: 2),
                      backgroundColor: AppColors.primaryBlack,
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _hostAddress.isNotEmpty
                ? 'Direct Host: $_hostAddress • PIN: $_roomPin'
                : 'Share this 4-digit PIN with nearby receivers to join',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedFilesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Selected Files · ${_selectedFiles.length} ${_selectedFiles.length == 1 ? 'file' : 'files'}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: AppColors.primaryBlack,
              ),
            ),
            if (_preparingCount > 0 || _queuedCount > 0)
              Text(
                '$_preparingCount hashing${_queuedCount > 0 ? ', $_queuedCount queued' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mediumGray,
                  fontWeight: FontWeight.w500,
                ),
              )
            else if (_readyCount == _selectedFiles.length && _selectedFiles.isNotEmpty)
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                  SizedBox(width: 4),
                  Text(
                    'All ready',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _selectedFiles.length,
          itemBuilder: (context, index) {
            final item = _selectedFiles[index];
            return _buildFileCard(item, index);
          },
        ),
      ],
    );
  }

  Widget _buildFileCard(PickedFileItem item, int index) {
    final isHashing = item.status == FilePreparationStatus.hashing;
    final isPreparing = item.status == FilePreparationStatus.preparing;
    final isReady = item.status == FilePreparationStatus.manifestReady ||
        item.status == FilePreparationStatus.hostingReady ||
        item.status == FilePreparationStatus.ready;
    final isError = item.status == FilePreparationStatus.error;

    return Container(
      key: ValueKey(item.id),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withValues(alpha: 0.5)
              : (isReady
                  ? Colors.green.withValues(alpha: 0.4)
                  : AppColors.borderGray),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _getFileIcon(item.info.type, item.info.extension),
                  size: 22,
                  color: _getFileIconColor(item.info.type, item.info.extension),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.info.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.info.formattedSize} • ${item.info.type.displayName}${item.info.extension.isNotEmpty ? '/${item.info.extension.toUpperCase()}' : ''}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.mediumGray,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Remove file',
                onPressed: () => _removeFileAt(index),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Status & Progress Area
          if (isHashing) ...[
            ValueListenableBuilder<ManifestProgress?>(
              valueListenable: item.progressNotifier,
              builder: (context, p, _) {
                final progressObj = p ?? item.progress;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.0,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Hashing manifest · ${progressObj?.percentage ?? 0}%',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (progressObj != null)
                              Text(
                                '${progressObj.formattedProcessedBytes} / ${item.info.formattedSize}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.mediumGray,
                                ),
                              ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () => _cancelPreparation(item),
                              borderRadius: BorderRadius.circular(4),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Text(
                                  'Cancel',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progressObj?.progress,
                        backgroundColor: AppColors.lightGray,
                        valueColor: const AlwaysStoppedAnimation(AppColors.primaryBlack),
                        minHeight: 4,
                      ),
                    ),
                  ],
                );
              },
            ),
          ] else if (isReady) ...[
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Manifest Ready · ${item.manifest?.chunkCount ?? (item.info.sizeBytes > 0 ? (item.info.sizeBytes / (1024 * 1024)).ceil() : 1)} chunks · SHA-256 verified',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (isPreparing) ...[
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    color: AppColors.mediumGray,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Preparing file access...',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.mediumGray,
                  ),
                ),
              ],
            ),
          ] else if (isError) ...[
            Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 16, color: Colors.redAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: ${item.errorMessage ?? 'Preparation failed'}',
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                  ),
                ),
                TextButton(
                  onPressed: () => _retryPreparation(item),
                  child: const Text('Retry', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ] else if (item.status == FilePreparationStatus.cancelled) ...[
            Row(
              children: [
                const Icon(Icons.cancel_outlined, size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Preparation cancelled',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _retryPreparation(item),
                  child: const Text('Prepare', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ] else ...[
            const Row(
              children: [
                Icon(Icons.hourglass_empty_rounded, size: 14, color: AppColors.mediumGray),
                SizedBox(width: 6),
                Text(
                  'Queued for preparation',
                  style: TextStyle(fontSize: 11, color: AppColors.mediumGray),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFloatingDeviceBubble() {
    final connectedCount = _nearbyDevices.length;
    final selectedCount = _selectedDeviceIds.length;

    return GestureDetector(
      onTap: _openConnectedDevicesSheet,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.primaryBlack,
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.devices_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: selectedCount > 0 ? Colors.green : Colors.white24,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                selectedCount > 0
                    ? '$selectedCount/$connectedCount'
                    : '$connectedCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[FluxShare] UI displays: ${_selectedFiles.length} files');

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Send Files'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.s16, AppSpacing.s16, AppSpacing.s16, 90),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. File Selection Summary Bar (or Select Card if empty)
                      _buildSelectionSummaryBar(),
                      const SizedBox(height: AppSpacing.s16),

                      // 2. Room PIN Display Card
                      _buildRoomPinCard(),
                      const SizedBox(height: AppSpacing.s20),

                      // 3. Selected Files Section (Cards below Room PIN)
                      if (_selectedFiles.isNotEmpty) ...[
                        _buildSelectedFilesSection(),
                        const SizedBox(height: AppSpacing.s24),
                      ],
                    ],
                  ),
                ),
              ),

              // 4. Start Transfer Action Area
              Container(
                padding: const EdgeInsets.all(AppSpacing.s16),
                decoration: const BoxDecoration(
                  color: AppColors.backgroundWhite,
                  border: Border(
                    top: BorderSide(color: AppColors.borderGray, width: 1.0),
                  ),
                ),
                child: SafeArea(
                  child: PrimaryButton(
                    text: _transferButtonText,
                    icon: Icons.send_rounded,
                    onPressed: _canStartTransfer ? _startTransfer : null,
                  ),
                ),
              ),
            ],
          ),

          // 5. Floating Device Bubble on right side
          Positioned(
            right: 16,
            bottom: 84,
            child: _buildFloatingDeviceBubble(),
          ),
        ],
      ),
    );
  }
}
