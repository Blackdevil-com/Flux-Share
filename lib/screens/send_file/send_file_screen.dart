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
  });

  bool get isReady => status.isManifestReady && manifest != null;
}

class SendFileScreen extends StatefulWidget {
  final FileInfo? initialFile;
  final String? initialDeviceId;

  const SendFileScreen({
    super.key,
    this.initialFile,
    this.initialDeviceId,
  });

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  final DeviceRepository _deviceRepository = DeviceRepository();
  final DiscoveryService _discoveryService = DiscoveryService();
  final List<PickedFileItem> _selectedFiles = [];
  final Set<String> _selectedDeviceIds = {};
  final ValueNotifier<int> _manifestUpdateNotifier = ValueNotifier<int>(0);
  bool _isQueueProcessing = false;
  List<Device> _nearbyDevices = [];
  bool _isLoadingDevices = true;
  late String _roomPin;
  String _hostAddress = '';

  @override
  void initState() {
    super.initState();
    _generateRoomPin();
    if (widget.initialFile != null) {
      final file = File(widget.initialFile!.id);
      _selectedFiles.add(
        PickedFileItem(
          id: widget.initialFile!.id,
          jobId: 1,
          file: file,
          info: widget.initialFile!,
          status: FilePreparationStatus.selected,
        ),
      );
      _startPreparationQueue();
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
      .where((i) => i.status == FilePreparationStatus.selected)
      .length;

  String get _batchSummaryText {
    final total = _selectedFiles.length;
    if (_readyCount == total && total > 0) {
      return '$total ${total == 1 ? 'file' : 'files'} selected ($_formattedTotalBytes) · All manifests ready';
    }
    return '$total ${total == 1 ? 'file' : 'files'} · $_readyCount ready · $_preparingCount preparing · $_queuedCount queued';
  }

  String get _formattedTotalBytes {
    final bytes = _totalSelectedBytes;
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
        if (_selectedFiles.any((item) =>
            item.file.path == path ||
            (item.info.name == payload.name && item.info.sizeBytes == payload.sizeBytes))) {
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
      }

      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');

      // Immediate UI update: all selected files appear on screen instantaneously
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

      // Start asynchronous manifest preparation pipeline
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

  Future<void> _changeFileAt(int index) async {
    if (index < 0 || index >= _selectedFiles.length) return;

    final targetItem = _selectedFiles[index];

    try {
      final replacement = await FilePickerService.pickSingleFilePayload();
      if (replacement == null) {
        // User cancelled picker: retain existing selection and preparation state
        debugPrint('[FluxShare] Change file cancelled by user, preserving previous selection');
        return;
      }

      // Check if the replacement file is already in another item
      final replacementPath = replacement.file.path;
      final duplicateIndex = _selectedFiles.indexWhere((item) =>
          item != targetItem &&
          (item.file.path == replacementPath ||
              (item.info.name == replacement.name && item.info.sizeBytes == replacement.sizeBytes)));
      if (duplicateIndex != -1) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selected file is already in the transfer list.'),
              backgroundColor: AppColors.primaryBlack,
            ),
          );
        }
        return;
      }

      // Invalidate existing preparation job immediately
      targetItem.isCancelled = true;
      final newJobId = ++targetItem.jobId;

      setState(() {
        targetItem.file = replacement.file;
        targetItem.info = replacement.toFileInfo();
        targetItem.status = FilePreparationStatus.selected;
        targetItem.manifest = null;
        targetItem.progress = null;
        targetItem.errorMessage = null;
        targetItem.isCancelled = false;
      });
      _manifestUpdateNotifier.value++;

      debugPrint('[FluxShare] File at index $index replaced with "${replacement.name}" (jobId: $newJobId)');

      // Immediately trigger preparation queue for the replacement
      _startPreparationQueue();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not replace file: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  void _cancelPreparation(PickedFileItem item) {
    item.isCancelled = true;
    ++item.jobId;
    setState(() {
      item.status = FilePreparationStatus.cancelled;
      item.progress = null;
    });
    _manifestUpdateNotifier.value++;
    debugPrint('[FluxShare] Preparation cancelled for "${item.info.name}"');
  }

  void _startPreparationQueue() {
    if (_isQueueProcessing) return;
    _isQueueProcessing = true;
    _processPreparationQueue();
  }

  Future<void> _processPreparationQueue() async {
    while (mounted) {
      PickedFileItem? targetItem;
      for (final item in _selectedFiles) {
        if (item.status == FilePreparationStatus.selected) {
          targetItem = item;
          break;
        }
      }

      if (targetItem == null) {
        break;
      }

      final int activeJobId = targetItem.jobId;

      try {
        if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
          setState(() {
            targetItem!.status = FilePreparationStatus.preparing;
          });
          _manifestUpdateNotifier.value++;
        }

        if (!await targetItem.file.exists()) {
          if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
            setState(() {
              targetItem!.status = FilePreparationStatus.error;
              targetItem.errorMessage = 'File not found on disk';
            });
            _manifestUpdateNotifier.value++;
          }
          continue;
        }

        if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
          setState(() {
            targetItem!.status = FilePreparationStatus.hashing;
          });
          _manifestUpdateNotifier.value++;
        }

        final manifest = await ManifestService.generateManifest(
          targetItem.file,
          fileId: targetItem.id,
          onProgress: (p) {
            if (mounted && targetItem!.jobId == activeJobId && !targetItem.isCancelled) {
              setState(() {
                targetItem!.progress = p;
              });
              _manifestUpdateNotifier.value++;
            }
          },
          isCancelled: () =>
              !mounted || targetItem!.jobId != activeJobId || targetItem.isCancelled,
        );

        if (mounted && targetItem.jobId == activeJobId && !targetItem.isCancelled) {
          setState(() {
            targetItem!.manifest = manifest;
            targetItem.status = FilePreparationStatus.manifestReady;
            targetItem.errorMessage = null;
          });
          _manifestUpdateNotifier.value++;
        }
      } catch (e) {
        if (mounted && targetItem.jobId == activeJobId) {
          setState(() {
            if (targetItem!.isCancelled) {
              targetItem.status = FilePreparationStatus.cancelled;
            } else {
              targetItem.status = FilePreparationStatus.error;
              targetItem.errorMessage = e.toString();
            }
          });
          _manifestUpdateNotifier.value++;
        }
      }
    }
    _isQueueProcessing = false;
  }

  void _retryPreparation(PickedFileItem item) {
    item.isCancelled = false;
    item.status = FilePreparationStatus.selected;
    item.errorMessage = null;
    item.progress = null;
    ++item.jobId;
    setState(() {});
    _manifestUpdateNotifier.value++;
    _startPreparationQueue();
  }

  void _removeFileAt(int index) {
    if (index >= 0 && index < _selectedFiles.length) {
      final removed = _selectedFiles[index];
      removed.isCancelled = true;
      ++removed.jobId;
      setState(() {
        _selectedFiles.removeAt(index);
      });
      _manifestUpdateNotifier.value++;
      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');
    }
  }

  void _clearAllFiles() {
    for (final item in _selectedFiles) {
      item.isCancelled = true;
      ++item.jobId;
    }
    setState(() {
      _selectedFiles.clear();
    });
    _manifestUpdateNotifier.value++;
    debugPrint('[FluxShare] Selection state contains: 0 files');
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

  IconData _getFileIcon(FileType type) {
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

  Future<void> _startTransfer() async {
    debugPrint('[FluxShare] Start Transfer received: ${_selectedFiles.length} files');
    if (!_canStartTransfer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please wait for all file manifests to finish preparing')),
      );
      return;
    }

    try {
      // Mark all files as hosting ready
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

      // Start local server and register all batch manifests
      final server = LocalServer();
      final port = await server.start();
      server.setBatchManifests(batchItems);

      // Start UDP room discovery host
      await _discoveryService.startRoomHost(
        pin: _roomPin,
        roomId: batchManifest.batchId,
        serverPort: port,
        deviceName: server.localDeviceName,
      );

      // Register with RoomManager
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

      if (mounted) {
        Navigator.of(context).pushReplacement(
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
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Room PIN Display Banner
                  Container(
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
                  ),
                  const SizedBox(height: AppSpacing.s20),
                  const SectionHeader(title: 'File Selection'),
                  if (_selectedFiles.isEmpty)
                    FilePickerCard(
                      onTap: _openFileBrowser,
                      title: 'Select File to Share',
                      subtitle: 'Tap to select files. Hashing and manifest preparation begin immediately.',
                    )
                  else ...[
                    // Selection summary bar
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                              _batchSummaryText,
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
                              TextButton.icon(
                                onPressed: _openFileBrowser,
                                icon: const Icon(Icons.add_rounded, size: 18),
                                label: const Text('Add More'),
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.primaryBlack,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                ),
                              ),
                              TextButton(
                                onPressed: _clearAllFiles,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                ),
                                child: const Text('Clear All'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Selected Files List
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _selectedFiles.length,
                      itemBuilder: (context, index) {
                        final item = _selectedFiles[index];
                        final isPreparing = item.status == FilePreparationStatus.preparing ||
                            item.status == FilePreparationStatus.hashing;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: item.status == FilePreparationStatus.error
                                  ? Colors.redAccent.withValues(alpha: 0.5)
                                  : (item.status == FilePreparationStatus.manifestReady
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
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: AppColors.lightGray,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      _getFileIcon(item.info.type),
                                      size: 20,
                                      color: AppColors.primaryBlack,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.info.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: AppColors.primaryBlack,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${item.info.formattedSize} • ${item.info.type.displayName}',
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
                              // Status & Progress Section
                              if (isPreparing) ...[
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      item.status == FilePreparationStatus.hashing
                                          ? 'Calculating SHA-256'
                                          : 'Building chunk manifest',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primaryBlack,
                                      ),
                                    ),
                                    Text(
                                      item.progress != null
                                          ? '${item.progress!.formattedProcessedBytes} / ${item.info.formattedSize} processed · ${item.progress!.percentage}%'
                                          : 'Starting...',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.mediumGray,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: item.progress?.progress,
                                    backgroundColor: AppColors.lightGray,
                                    valueColor: const AlwaysStoppedAnimation(AppColors.primaryBlack),
                                    minHeight: 4,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () => _changeFileAt(index),
                                      icon: const Icon(Icons.swap_horiz_rounded, size: 15),
                                      label: const Text('Change File'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppColors.primaryBlack,
                                        side: const BorderSide(color: AppColors.borderGray),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: () => _cancelPreparation(item),
                                      icon: const Icon(Icons.cancel_outlined, size: 15, color: Colors.redAccent),
                                      label: const Text('Cancel', style: TextStyle(color: Colors.redAccent)),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ] else if (item.status == FilePreparationStatus.manifestReady) ...[
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.check_circle_rounded, size: 15, color: Colors.green),
                                        SizedBox(width: 4),
                                        Text(
                                          'Manifest Ready · Verified SHA-256',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                      ],
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _changeFileAt(index),
                                      icon: const Icon(Icons.swap_horiz_rounded, size: 14, color: AppColors.primaryBlack),
                                      label: const Text('Change', style: TextStyle(fontSize: 11, color: AppColors.primaryBlack, fontWeight: FontWeight.w600)),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ] else if (item.status == FilePreparationStatus.cancelled) ...[
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.cancel_outlined, size: 15, color: Colors.orange[800]),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Preparation Cancelled',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.orange[800],
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextButton.icon(
                                          onPressed: () => _retryPreparation(item),
                                          icon: const Icon(Icons.refresh_rounded, size: 14, color: AppColors.primaryBlack),
                                          label: const Text('Resume / Retry', style: TextStyle(fontSize: 11, color: AppColors.primaryBlack, fontWeight: FontWeight.w600)),
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        TextButton.icon(
                                          onPressed: () => _changeFileAt(index),
                                          icon: const Icon(Icons.swap_horiz_rounded, size: 14, color: AppColors.primaryBlack),
                                          label: const Text('Change', style: TextStyle(fontSize: 11, color: AppColors.primaryBlack, fontWeight: FontWeight.w600)),
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ] else if (item.status == FilePreparationStatus.error) ...[
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Error: ${item.errorMessage ?? 'Preparation failed'}',
                                      style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        OutlinedButton.icon(
                                          onPressed: () => _retryPreparation(item),
                                          icon: const Icon(Icons.refresh_rounded, size: 14, color: Colors.redAccent),
                                          label: const Text('Retry', style: TextStyle(color: Colors.redAccent)),
                                          style: OutlinedButton.styleFrom(
                                            side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        OutlinedButton.icon(
                                          onPressed: () => _changeFileAt(index),
                                          icon: const Icon(Icons.swap_horiz_rounded, size: 14, color: AppColors.primaryBlack),
                                          label: const Text('Change File'),
                                          style: OutlinedButton.styleFrom(
                                            side: const BorderSide(color: AppColors.borderGray),
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ] else ...[
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.hourglass_empty_rounded, size: 14, color: AppColors.mediumGray),
                                        SizedBox(width: 4),
                                        Text(
                                          'Queued for preparation...',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.mediumGray,
                                          ),
                                        ),
                                      ],
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _changeFileAt(index),
                                      icon: const Icon(Icons.swap_horiz_rounded, size: 14, color: AppColors.primaryBlack),
                                      label: const Text('Change', style: TextStyle(fontSize: 11, color: AppColors.primaryBlack, fontWeight: FontWeight.w600)),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SectionHeader(
                        title: 'Select Receivers',
                        padding: EdgeInsets.zero,
                      ),
                      if (_selectedDeviceIds.isNotEmpty)
                        Text(
                          '${_selectedDeviceIds.length} selected',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s12),
                  if (_isLoadingDevices)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.s24),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primaryBlack,
                        ),
                      ),
                    )
                  else if (_nearbyDevices.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.s24),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.borderGray),
                      ),
                      child: const Column(
                        children: [
                          Icon(
                            Icons.devices_other_rounded,
                            size: 36,
                            color: AppColors.mediumGray,
                          ),
                          SizedBox(height: AppSpacing.s8),
                          Text(
                            'No nearby devices found',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Make sure nearby devices have FluxShare active.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.mediumGray,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  else
                    Column(
                      children: _nearbyDevices.map((device) {
                        final isSelected = _selectedDeviceIds.contains(device.id);
                        return DeviceListItem(
                          device: device,
                          isSelected: isSelected,
                          onSelectedChanged: (val) => _toggleDeviceSelection(device.id),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
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
    );
  }
}
