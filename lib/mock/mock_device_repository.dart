import '../models/device.dart';
import 'mock_data.dart';

class MockDeviceRepository {
  List<Device> _devices = List.from(MockData.mockDevices);

  Future<List<Device>> getNearbyDevices() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return List.unmodifiable(_devices);
  }

  Future<List<Device>> scanDevices() async {
    await Future.delayed(const Duration(seconds: 1));
    _devices = MockData.mockDevices.map((device) {
      if (device.id == 'dev_4') {
        return device.copyWith(isAvailable: true, signalStrength: 3);
      }
      return device;
    }).toList();
    return List.unmodifiable(_devices);
  }
}
