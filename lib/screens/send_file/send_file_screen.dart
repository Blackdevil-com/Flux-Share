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

class PickedFileItem {
  final File file;
  final FileInfo info;
  const PickedFileItem({required this.file, required this.info});
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
  List<Device> _nearbyDevices = [];
  bool _isLoadingDevices = true;
  late String _roomPin;
  String _hostAddress = '';

  @override
  void initState() {
    super.initState();
    _generateRoomPin();
    if (widget.initialFile != null) {
      _selectedFiles.add(
        PickedFileItem(
          file: File(widget.initialFile!.id),
          info: widget.initialFile!,
        ),
      );
    }
    if (widget.initialDeviceId != null) {
      _selectedDeviceIds.add(widget.initialDeviceId!);
    }
    _loadDevices();
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

  String get _formattedTotalBytes {
    final bytes = _totalSelectedBytes;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _getCanonicalPath(File file) {
    try {
      return file.resolveSymbolicLinksSync();
    } catch (_) {
      return file.absolute.path;
    }
  }

  Future<void> _openFileBrowser() async {
    try {
      final pickedFiles = await FilePickerService.pickMultipleFiles();
      if (pickedFiles.isEmpty) {
        debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');
        return;
      }

      int addedCount = 0;
      for (final file in pickedFiles) {
        if (!await file.exists()) {
          debugPrint('[FluxShare] Inaccessible file: ${file.path}');
          continue;
        }

        // Prevent duplicate file selection by canonical path
        final canonicalPath = _getCanonicalPath(file);
        if (_selectedFiles.any((item) => _getCanonicalPath(item.file) == canonicalPath)) {
          continue;
        }

        final info = await FileInfo.fromFile(file);
        _selectedFiles.add(PickedFileItem(file: file, info: info));
        addedCount++;
      }

      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');

      if (mounted) {
        setState(() {});
        if (addedCount == 0 && pickedFiles.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selected files are already in the transfer list.'),
              backgroundColor: AppColors.primaryBlack,
            ),
          );
        }
      }
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

  void _removeFileAt(int index) {
    if (index >= 0 && index < _selectedFiles.length) {
      setState(() {
        _selectedFiles.removeAt(index);
      });
      debugPrint('[FluxShare] Selection state contains: ${_selectedFiles.length} files');
    }
  }

  void _clearAllFiles() {
    setState(() {
      _selectedFiles.clear();
    });
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
    if (_selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one file to transfer')),
      );
      return;
    }

    // Verify all selected files exist on disk
    for (final item in _selectedFiles) {
      if (!await item.file.exists()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File "${item.info.name}" not found on disk')),
        );
        return;
      }
    }

    // Show loading dialog while hashing and chunking
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: AppColors.primaryBlack),
                const SizedBox(height: 16),
                Text(
                  'Hashing ${_selectedFiles.length} ${_selectedFiles.length == 1 ? 'file' : 'files'} & preparing manifests...',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final List<Manifest> manifests = [];
      final List<({Manifest manifest, File file})> batchItems = [];

      for (final item in _selectedFiles) {
        final m = await ManifestService.createManifest(item.file);
        manifests.add(m);
        batchItems.add((manifest: m, file: item.file));
      }

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
        Navigator.of(context).pop(); // dismiss loading dialog
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
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error preparing transfer: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[FluxShare] UI displays: ${_selectedFiles.length} files');
    final bool canStartTransfer = _selectedFiles.isNotEmpty;

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
                      title: 'Tap to select files',
                      subtitle: 'Select multiple files or documents',
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
                              '${_selectedFiles.length} ${_selectedFiles.length == 1 ? 'file' : 'files'} selected ($_formattedTotalBytes)',
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
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundWhite,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.borderGray),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
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
                text: _selectedFiles.length > 1
                    ? 'START BATCH TRANSFER (${_selectedFiles.length})'
                    : 'START TRANSFER',
                icon: Icons.send_rounded,
                onPressed: canStartTransfer ? _startTransfer : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
