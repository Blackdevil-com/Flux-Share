import 'dart:async';
import '../discovery/discovery_service.dart';
import '../models/device.dart';
import '../peer/peer_manager.dart';

/// Real device repository scanning local network via UDP discovery.
/// Never returns fake mock devices or falls back to localhost.
class DeviceRepository {
  static final DeviceRepository _instance = DeviceRepository._internal();
  factory DeviceRepository() => _instance;
  DeviceRepository._internal();

  final DiscoveryService _discoveryService = DiscoveryService();
  final PeerManager _peerManager = PeerManager();

  final List<Device> _devices = [];
  final _deviceStreamController = StreamController<List<Device>>.broadcast();

  Stream<List<Device>> get devicesStream => _deviceStreamController.stream;

  Future<List<Device>> getNearbyDevices() async {
    return List.unmodifiable(_devices);
  }

  /// Performs real UDP broadcast discovery on the local Wi-Fi subnet.
  Future<List<Device>> scanDevices() async {
    final peers = await _discoveryService.scanNearbyPeers(timeout: const Duration(seconds: 2));

    _devices.clear();
    for (final p in peers) {
      _peerManager.addOrUpdatePeer(p);
      _devices.add(
        Device(
          id: p.peerId,
          name: p.deviceName,
          platform: DevicePlatform.fromString(p.platform),
          isAvailable: p.connectionStatus != 'disconnected',
          signalStrength: 4,
        ),
      );
    }

    _deviceStreamController.add(List.unmodifiable(_devices));
    return List.unmodifiable(_devices);
  }
}
