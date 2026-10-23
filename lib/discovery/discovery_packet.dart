import 'dart:convert';

/// Packet structure exchanged over UDP port 8888 for room discovery and peer presence.
class DiscoveryPacket {
  final String action; // "DISCOVER_ROOM" | "ROOM_FOUND" | "PEER_DISCOVERY" | "PEER_ANNOUNCE"
  final String? pin;
  final String? roomId;
  final String? peerId;
  final String? ip;
  final int? port;
  final String? deviceName;
  final String? platform;

  DiscoveryPacket({
    required this.action,
    this.pin,
    this.roomId,
    this.peerId,
    this.ip,
    this.port,
    this.deviceName,
    this.platform,
  });

  Map<String, dynamic> toJson() => {
        'action': action,
        if (pin != null) 'pin': pin,
        if (roomId != null) 'roomId': roomId,
        if (peerId != null) 'peerId': peerId,
        if (ip != null) 'ip': ip,
        if (port != null) 'port': port,
        if (deviceName != null) 'deviceName': deviceName,
        if (platform != null) 'platform': platform,
      };

  String encode() => jsonEncode(toJson());

  factory DiscoveryPacket.fromJson(Map<String, dynamic> json) => DiscoveryPacket(
        action: json['action'] as String? ?? '',
        pin: json['pin'] as String?,
        roomId: json['roomId'] as String?,
        peerId: json['peerId'] as String?,
        ip: json['ip'] as String?,
        port: (json['port'] as num?)?.toInt(),
        deviceName: json['deviceName'] as String?,
        platform: json['platform'] as String?,
      );

  static DiscoveryPacket? tryDecode(String text) {
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      return DiscoveryPacket.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}
