import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/theme.dart';
import '../../discovery/discovery_service.dart';
import '../../file/file_picker_service.dart';
import '../../file/manifest_service.dart';
import '../../models/device.dart';
import '../../models/file_info.dart';
import '../../models/manifest.dart';
import '../../network/local_server.dart';
import '../../network/network_utils.dart';
import '../../repositories/device_repository.dart';
import '../../room/room_manager.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_progress_screen.dart';

class SendFileScreen extends StatefulWidget {
  final FileInfo? initialFile;
  final String? initialDeviceId;
  final Manifest? initialManifest;

  const SendFileScreen({
    super.key,
    this.initialFile,
    this.initialDeviceId,
    this.initialManifest,
  });

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  final DeviceRepository _deviceRepository = DeviceRepository();
  final DiscoveryService _discoveryService = DiscoveryService();
  FileInfo? _selectedFile;
  File? _pickedFile;
  Manifest? _manifest;
  bool _isPreparingManifest = false;
  ManifestProgress? _manifestProgress;
  int _manifestJobId = 0;
  bool _isCancelled = false;
  String? _manifestError;

  final Set<String> _selectedDeviceIds = {};
  List<Device> _nearbyDevices = [];
  bool _isLoadingDevices = true;
  late String _roomPin;
  String _hostAddress = '';

  @override
  void initState() {
    super.initState();
    _generateRoomPin();
    _selectedFile = widget.initialFile;
    if (_selectedFile != null) {
      _pickedFile = File(_selectedFile!.id);
      if (widget.initialManifest != null) {
        _manifest = widget.initialManifest;
      } else {
        _prepareManifestForSelectedFile();
      }
    }
    if (widget.initialDeviceId != null) {
      _selectedDeviceIds.add(widget.initialDeviceId!);
    }
    _loadDevices();
  }

  @override
  void dispose() {
    _isCancelled = true;
    _manifestJobId++;
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

  Future<void> _openFileBrowser() async {
    final file = await FilePickerService.pickSingleFile();
    if (file != null && mounted) {
      final info = await FileInfo.fromFile(file);
      setState(() {
        _pickedFile = file;
        _selectedFile = info;
      });
      _prepareManifestForSelectedFile();
    }
  }

  void _prepareManifestForSelectedFile() {
    if (_pickedFile == null && _selectedFile != null) {
      _pickedFile = File(_selectedFile!.id);
    }
    if (_pickedFile == null) return;

    _isCancelled = false;
    final int jobId = ++_manifestJobId;

    setState(() {
      _manifest = null;
      _isPreparingManifest = true;
      _manifestProgress = null;
      _manifestError = null;
    });

    ManifestService.generateManifest(
      _pickedFile!,
      onProgress: (p) {
        if (mounted && _manifestJobId == jobId && !_isCancelled) {
          setState(() {
            _manifestProgress = p;
          });
        }
      },
      isCancelled: () => !mounted || _manifestJobId != jobId || _isCancelled,
    ).then((manifest) {
      if (mounted && _manifestJobId == jobId && !_isCancelled) {
        setState(() {
          _manifest = manifest;
          _isPreparingManifest = false;
          _manifestError = null;
        });
      }
    }).catchError((e) {
      if (mounted && _manifestJobId == jobId && !_isCancelled) {
        setState(() {
          _isPreparingManifest = false;
          _manifestError = e.toString();
        });
      }
    });
  }

  void _removeSelectedFile() {
    _isCancelled = true;
    _manifestJobId++;
    setState(() {
      _selectedFile = null;
      _pickedFile = null;
      _manifest = null;
      _isPreparingManifest = false;
      _manifestProgress = null;
      _manifestError = null;
    });
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

  Future<void> _startTransfer() async {
    if (_selectedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a file to transfer')),
      );
      return;
    }

    _pickedFile ??= File(_selectedFile!.id);

    if (!await _pickedFile!.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected file does not exist on disk')),
      );
      return;
    }

    // If manifest is still calculating, show responsive progress dialog with cancel option
    if (_manifest == null && _isPreparingManifest) {
      if (!mounted) return;
      bool dialogDismissedByCancel = false;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StreamBuilder<int>(
            stream: Stream.periodic(const Duration(milliseconds: 100), (i) => i),
            builder: (context, snapshot) {
              if (_manifest != null && mounted) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (Navigator.of(ctx).canPop()) {
                    Navigator.of(ctx).pop();
                  }
                });
              }
              return AlertDialog(
                backgroundColor: AppColors.backgroundWhite,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primaryBlack),
                    ),
                    SizedBox(width: 12),
                    Text('Preparing Manifest', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _manifestProgress?.progress,
                        minHeight: 6,
                        backgroundColor: AppColors.lightGray,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _manifestProgress != null
                              ? '${_manifestProgress!.percentage}% completed'
                              : 'Calculating SHA-256...',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primaryBlack),
                        ),
                        if (_manifestProgress != null)
                          Text(
                            '${_manifestProgress!.currentChunk}/${_manifestProgress!.totalChunks} chunks',
                            style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                          ),
                      ],
                    ),
                    if (_manifestProgress != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${_manifestProgress!.formattedProcessedBytes} of ${_manifestProgress!.formattedTotalBytes}',
                        style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      dialogDismissedByCancel = true;
                      Navigator.of(ctx).pop();
                    },
                    child: const Text('Cancel', style: TextStyle(color: Colors.redAccent)),
                  ),
                ],
              );
            },
          );
        },
      );

      if (dialogDismissedByCancel || _manifest == null) {
        return;
      }
    }

    if (_manifest == null) {
      try {
        _manifest = await ManifestService.createManifest(_pickedFile!);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not prepare manifest: $e')),
          );
        }
        return;
      }
    }

    final manifest = _manifest!;

    try {
      // Start local server
      final server = LocalServer();
      final port = await server.start();
      server.setManifest(manifest, _pickedFile!);

      // Start UDP room discovery host
      await _discoveryService.startRoomHost(
        pin: _roomPin,
        roomId: manifest.fileId,
        serverPort: port,
        deviceName: server.localDeviceName,
      );

      // Register with RoomManager
      RoomManager().createRoom(
        hostPeerId: server.localPeerId,
        hostDeviceName: server.localDeviceName,
        customPin: _roomPin,
        manifest: manifest,
      );

      final List<Device> selectedDevices = _nearbyDevices
          .where((d) => _selectedDeviceIds.contains(d.id))
          .toList();

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => TransferProgressScreen(
              fileInfo: _selectedFile,
              sourceFile: _pickedFile,
              manifest: manifest,
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
          SnackBar(
            content: Text('Failed to initialize transfer: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  Widget _buildSelectedFileCard() {
    final info = _selectedFile!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(
          color: _manifest != null ? Colors.green.withValues(alpha: 0.4) : AppColors.borderGray,
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _getFileIcon(info.type),
                  size: 24,
                  color: AppColors.primaryBlack,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${info.formattedSize} • ${info.type.displayName}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.mediumGray,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _openFileBrowser,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Change', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: 'Remove',
                    onPressed: _removeSelectedFile,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Status & Progress Area
          if (_isPreparingManifest) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _manifestProgress?.progress,
                minHeight: 4,
                backgroundColor: AppColors.lightGray,
                color: AppColors.primaryBlack,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryBlack),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _manifestProgress != null
                          ? 'Hashing manifest · ${_manifestProgress!.percentage}%'
                          : 'Preparing file access...',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                  ],
                ),
                if (_manifestProgress != null)
                  Text(
                    '${_manifestProgress!.formattedProcessedBytes} / ${info.formattedSize}',
                    style: const TextStyle(fontSize: 11, color: AppColors.mediumGray),
                  ),
              ],
            ),
          ] else if (_manifest != null) ...[
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, size: 16, color: Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Manifest Ready · ${_manifest!.chunkCount} chunks · SHA-256 verified',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (_manifestError != null) ...[
            Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 16, color: Colors.redAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Error: $_manifestError',
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                  ),
                ),
                TextButton(
                  onPressed: _prepareManifestForSelectedFile,
                  child: const Text('Retry', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.Video:
        return Icons.video_file_rounded;
      case FileType.Image:
        return Icons.image_rounded;
      case FileType.Document:
        return Icons.description_rounded;
      case FileType.Archive:
        return Icons.folder_zip_rounded;
      case FileType.Presentation:
        return Icons.slideshow_rounded;
      case FileType.Other:
        return Icons.insert_drive_file_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canStartTransfer = _selectedFile != null;

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Send File'),
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
                  if (_selectedFile == null)
                    FilePickerCard(
                      onTap: _openFileBrowser,
                      title: 'Tap to select a file',
                      subtitle: 'Browse your storage',
                    )
                  else
                    _buildSelectedFileCard(),
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
                text: 'START TRANSFER',
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
