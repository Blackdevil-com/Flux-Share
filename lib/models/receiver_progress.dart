import 'device.dart';

class ReceiverProgress {
  final String? peerId;
  final String deviceName;
  final DevicePlatform devicePlatform;
  final double progressPercent; // 0 to 100
  final bool isCompleted;

  const ReceiverProgress({
    String? peerId,
    String? deviceId,
    required this.deviceName,
    this.devicePlatform = DevicePlatform.Android,
    this.progressPercent = 0.0,
    this.isCompleted = false,
  }) : peerId = peerId ?? deviceId;

  String? get deviceId => peerId;
  double get percent => progressPercent;

  ReceiverProgress copyWith({
    String? peerId,
    String? deviceName,
    DevicePlatform? devicePlatform,
    double? progressPercent,
    bool? isCompleted,
  }) {
    return ReceiverProgress(
      peerId: peerId ?? this.peerId,
      deviceName: deviceName ?? this.deviceName,
      devicePlatform: devicePlatform ?? this.devicePlatform,
      progressPercent: progressPercent ?? this.progressPercent,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'peerId': peerId,
      'deviceName': deviceName,
      'devicePlatform': devicePlatform.displayName,
      'progressPercent': progressPercent,
      'isCompleted': isCompleted,
    };
  }

  factory ReceiverProgress.fromMap(Map<String, dynamic> map) {
    return ReceiverProgress(
      peerId: map['peerId'] as String?,
      deviceName: map['deviceName'] ?? '',
      devicePlatform: DevicePlatform.fromString(map['devicePlatform'] ?? ''),
      progressPercent: (map['progressPercent'] as num?)?.toDouble() ?? 0.0,
      isCompleted: (map['isCompleted'] as bool?) ?? false,
    );
  }
}
