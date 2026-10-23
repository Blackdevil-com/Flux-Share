import 'device.dart';

class ReceiverProgress {
  final String deviceName;
  final DevicePlatform devicePlatform;
  final double progressPercent; // 0 to 100

  const ReceiverProgress({
    required this.deviceName,
    required this.devicePlatform,
    required this.progressPercent,
  });

  ReceiverProgress copyWith({
    String? deviceName,
    DevicePlatform? devicePlatform,
    double? progressPercent,
  }) {
    return ReceiverProgress(
      deviceName: deviceName ?? this.deviceName,
      devicePlatform: devicePlatform ?? this.devicePlatform,
      progressPercent: progressPercent ?? this.progressPercent,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'deviceName': deviceName,
      'devicePlatform': devicePlatform.displayName,
      'progressPercent': progressPercent,
    };
  }

  factory ReceiverProgress.fromMap(Map<String, dynamic> map) {
    return ReceiverProgress(
      deviceName: map['deviceName'] ?? '',
      devicePlatform: DevicePlatform.fromString(map['devicePlatform'] ?? ''),
      progressPercent: (map['progressPercent'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
