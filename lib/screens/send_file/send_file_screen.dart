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
import '../../repositories/device_repository.dart';
import '../../room/room_manager.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_progress_screen.dart';

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
  FileInfo? _selectedFile;
  File? _pickedFile;
  final Set<String> _selectedDeviceIds = {};
  List<Device> _nearbyDevices = [];
  bool _isLoadingDevices = true;
  late String _roomPin;

  @override
  void initState() {
    super.initState();
    _generateRoomPin();
    _selectedFile = widget.initialFile;
    if (widget.initialDeviceId != null) {
      _selectedDeviceIds.add(widget.initialDeviceId!);
    }
    _loadDevices();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _generateRoomPin() {
    _roomPin = (1000 + Random().nextInt(9000)).toString();
  }

  Future<void> _loadDevices() async {
    final devices = await _deviceRepository.getNearbyDevices();
    if (mounted) {
      setState(() {
        _nearbyDevices = devices;
        _isLoadingDevices = false;
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

  Future<void> _startTransfer() async {
    if (_selectedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a file to transfer')),
      );
      return;
    }

    if (_pickedFile == null) {
      _pickedFile = File(_selectedFile!.id);
    }

    if (!await _pickedFile!.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected file does not exist on disk')),
      );
      return;
    }

    // Show loading dialog while hashing and chunking
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Hashing file & preparing manifest...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final manifest = await ManifestService.createManifest(_pickedFile!);

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

      List<Device> selectedDevices = _nearbyDevices
          .where((d) => _selectedDeviceIds.contains(d.id))
          .toList();

      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading dialog
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
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error preparing transfer: $e')),
        );
      }
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
                        const Text(
                          'Share this 4-digit PIN with nearby receivers to join',
                          style: TextStyle(
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
                    FileCard(
                      fileInfo: _selectedFile!,
                      onRemove: () {
                        setState(() {
                          _selectedFile = null;
                        });
                      },
                    ),
                  const SizedBox(height: AppSpacing.s24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      SectionHeader(
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
                    const Center(
                      padding: EdgeInsets.all(AppSpacing.s24),
                      child: CircularProgressIndicator(
                        color: AppColors.primaryBlack,
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
