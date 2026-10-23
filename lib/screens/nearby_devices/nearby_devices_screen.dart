import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../models/device.dart';
import '../../repositories/device_repository.dart';
import '../../widgets/widgets.dart';
import '../send_file/send_file_screen.dart';

class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key});

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen>
    with SingleTickerProviderStateMixin {
  final DeviceRepository _repository = DeviceRepository();
  late AnimationController _pulseController;
  List<Device> _devices = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _loadInitialDevices();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialDevices() async {
    setState(() {
      _isScanning = true;
    });
    final devices = await _repository.getNearbyDevices();
    if (mounted) {
      setState(() {
        _devices = devices;
        _isScanning = false;
      });
    }
  }

  Future<void> _scanDevices() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
    });
    final updated = await _repository.scanDevices();
    if (mounted) {
      setState(() {
        _devices = updated;
        _isScanning = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device list refreshed'),
          backgroundColor: AppColors.primaryBlack,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isScanning ? Icons.sync_rounded : Icons.refresh_rounded,
              color: AppColors.primaryBlack,
            ),
            onPressed: _isScanning ? null : _scanDevices,
            tooltip: 'Refresh devices',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildRadarHeader(),
          const Divider(),
          Expanded(
            child: _devices.isEmpty && !_isScanning
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.radar_rounded,
                          size: 48,
                          color: AppColors.mediumGray,
                        ),
                        const SizedBox(height: AppSpacing.s16),
                        const Text(
                          'No nearby devices found',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s8),
                        const Text(
                          'Tap refresh or verify Wi-Fi is enabled on target devices.',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.mediumGray,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.s20),
                        SecondaryButton(
                          text: 'Refresh Search',
                          icon: Icons.refresh_rounded,
                          isExpanded: false,
                          onPressed: _scanDevices,
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return DeviceListItem(
                        device: device,
                        onTap: () {
                          if (device.isAvailable) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => SendFileScreen(
                                  initialDeviceId: device.id,
                                ),
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('${device.name} is currently busy'),
                                backgroundColor: AppColors.darkGray,
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.s20,
        horizontal: AppSpacing.s16,
      ),
      color: AppColors.lightGray.withOpacity(0.5),
      child: Column(
        children: [
          SizedBox(
            height: 90,
            width: 90,
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isScanning) ...[
                      Container(
                        width: 90 * _pulseController.value,
                        height: 90 * _pulseController.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.primaryBlack.withOpacity(
                              (1.0 - _pulseController.value).clamp(0.0, 1.0),
                            ),
                            width: 1.5,
                          ),
                        ),
                      ),
                      Container(
                        width: 60 * _pulseController.value,
                        height: 60 * _pulseController.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.primaryBlack.withOpacity(
                              (1.0 - _pulseController.value * 0.8).clamp(0.0, 1.0),
                            ),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ],
                    Container(
                      width: 50,
                      height: 50,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryBlack,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isScanning ? Icons.radar_rounded : Icons.cell_tower_rounded,
                        color: AppColors.backgroundWhite,
                        size: 26,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            _isScanning
                ? 'Searching for nearby devices...'
                : '${_devices.length} nearby devices active',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Keep FluxShare open on both devices for discovery',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.mediumGray,
            ),
          ),
        ],
      ),
    );
  }
}
