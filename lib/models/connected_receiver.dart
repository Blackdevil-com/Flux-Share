import 'device.dart';

/// The lifecycle state of a connected receiver peer.
enum ReceiverStatus {
  joining,
  connected,
  ready,
  receiving,
  completed,
  failed,
  disconnected;

  String get displayName {
    switch (this) {
      case ReceiverStatus.joining:
        return 'Joining';
      case ReceiverStatus.connected:
        return 'Connected';
      case ReceiverStatus.ready:
        return 'Ready';
      case ReceiverStatus.receiving:
        return 'Receiving';
      case ReceiverStatus.completed:
        return 'Completed';
      case ReceiverStatus.failed:
        return 'Failed';
      case ReceiverStatus.disconnected:
        return 'Disconnected';
    }
  }
}

/// Authoritative point-in-time record of a receiver peer in an active room session.
class ConnectedReceiver {
  final String peerId;
  final String deviceName;
  final DevicePlatform platform;
  final String? ip;
  final ReceiverStatus status;
  final double progressPercent;
  final int bytesReceived;
  final String? errorMessage;
  final DateTime lastSeen;

  const ConnectedReceiver({
    required this.peerId,
    required this.deviceName,
    this.platform = DevicePlatform.Android,
    this.ip,
    this.status = ReceiverStatus.joining,
    this.progressPercent = 0.0,
    this.bytesReceived = 0,
    this.errorMessage,
    required this.lastSeen,
  });

  ConnectedReceiver copyWith({
    String? peerId,
    String? deviceName,
    DevicePlatform? platform,
    String? ip,
    ReceiverStatus? status,
    double? progressPercent,
    int? bytesReceived,
    String? errorMessage,
    DateTime? lastSeen,
  }) {
    return ConnectedReceiver(
      peerId: peerId ?? this.peerId,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      ip: ip ?? this.ip,
      status: status ?? this.status,
      progressPercent: progressPercent ?? this.progressPercent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      errorMessage: errorMessage ?? this.errorMessage,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'deviceName': deviceName,
    'platform': platform.displayName,
    'ip': ip,
    'status': status.name,
    'progressPercent': progressPercent,
    'bytesReceived': bytesReceived,
    'errorMessage': errorMessage,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory ConnectedReceiver.fromJson(Map<String, dynamic> json) {
    return ConnectedReceiver(
      peerId: json['peerId'] as String? ?? 'unknown',
      deviceName: json['deviceName'] as String? ?? 'Receiver',
      platform: DevicePlatform.fromString(json['platform'] as String? ?? ''),
      ip: json['ip'] as String?,
      status: ReceiverStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ReceiverStatus.connected,
      ),
      progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
      bytesReceived: (json['bytesReceived'] as num?)?.toInt() ?? 0,
      errorMessage: json['errorMessage'] as String?,
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
