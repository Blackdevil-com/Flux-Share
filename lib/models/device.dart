enum DevicePlatform {
  iPhone,
  Android,
  Windows;

  String get displayName {
    switch (this) {
      case DevicePlatform.iPhone:
        return 'iPhone';
      case DevicePlatform.Android:
        return 'Android';
      case DevicePlatform.Windows:
        return 'Windows';
    }
  }

  static DevicePlatform fromString(String val) {
    switch (val.toLowerCase()) {
      case 'iphone':
      case 'ios':
        return DevicePlatform.iPhone;
      case 'windows':
      case 'pc':
        return DevicePlatform.Windows;
      case 'android':
      default:
        return DevicePlatform.Android;
    }
  }
}

class Device {
  final String id;
  final String name;
  final DevicePlatform platform;
  final bool isAvailable;
  final int signalStrength; // 1-4

  const Device({
    required this.id,
    required this.name,
    required this.platform,
    required this.isAvailable,
    required this.signalStrength,
  });

  Device copyWith({
    String? id,
    String? name,
    DevicePlatform? platform,
    bool? isAvailable,
    int? signalStrength,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      isAvailable: isAvailable ?? this.isAvailable,
      signalStrength: signalStrength ?? this.signalStrength,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'platform': platform.displayName,
      'isAvailable': isAvailable,
      'signalStrength': signalStrength,
    };
  }

  factory Device.fromMap(Map<String, dynamic> map) {
    return Device(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      platform: DevicePlatform.fromString(map['platform'] ?? ''),
      isAvailable: map['isAvailable'] ?? true,
      signalStrength: map['signalStrength'] ?? 4,
    );
  }
}
