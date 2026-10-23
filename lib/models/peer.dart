/// Canonical PeerInfo model tracking a member in the P2P swarm.
class PeerInfo {
  final String peerId;
  final String deviceName;
  final String platform; // "android" | "ios"
  final String ip;
  final int httpPort;
  final int webSocketPort;
  Set<int> availableChunks; // VERIFIED chunks only
  double emaThroughput;
  double successRate;
  int activeRequests;
  int lastSeenMillis;
  String connectionStatus; // "available" | "stale" | "disconnected"

  PeerInfo({
    required this.peerId,
    required this.deviceName,
    required this.platform,
    required this.ip,
    required this.httpPort,
    required this.webSocketPort,
    Set<int>? availableChunks,
    this.emaThroughput = 0.0,
    this.successRate = 1.0,
    this.activeRequests = 0,
    this.lastSeenMillis = 0,
    this.connectionStatus = 'available',
  }) : availableChunks = availableChunks ?? <int>{};

  void touch() {
    lastSeenMillis = DateTime.now().millisecondsSinceEpoch;
    if (connectionStatus == 'stale' || connectionStatus == 'disconnected') {
      connectionStatus = 'available';
    }
  }

  void updateThroughput(double speedMbPerSec) {
    if (speedMbPerSec <= 0) return;
    if (emaThroughput <= 0.0) {
      emaThroughput = speedMbPerSec;
    } else {
      emaThroughput = (0.3 * speedMbPerSec) + (0.7 * emaThroughput);
    }
  }

  void recordSuccess() {
    touch();
    successRate = (successRate * 0.9) + 0.1;
  }

  void recordFailure() {
    touch();
    successRate = (successRate * 0.8);
  }

  Map<String, dynamic> toJson() => {
        'peerId': peerId,
        'deviceName': deviceName,
        'platform': platform,
        'ip': ip,
        'httpPort': httpPort,
        'webSocketPort': webSocketPort,
        'availableChunks': availableChunks.toList(),
        'emaThroughput': emaThroughput,
        'successRate': successRate,
        'activeRequests': activeRequests,
        'lastSeenMillis': lastSeenMillis,
        'connectionStatus': connectionStatus,
      };

  factory PeerInfo.fromJson(Map<String, dynamic> json) => PeerInfo(
        peerId: json['peerId'] as String,
        deviceName: json['deviceName'] as String,
        platform: (json['platform'] as String?) ?? 'android',
        ip: json['ip'] as String,
        httpPort: (json['httpPort'] as num).toInt(),
        webSocketPort: (json['webSocketPort'] as num?)?.toInt() ?? (json['httpPort'] as num).toInt(),
        availableChunks: (json['availableChunks'] as List<dynamic>?)
                ?.map((e) => (e as num).toInt())
                .toSet() ??
            <int>{},
        emaThroughput: (json['emaThroughput'] as num?)?.toDouble() ?? 0.0,
        successRate: (json['successRate'] as num?)?.toDouble() ?? 1.0,
        activeRequests: (json['activeRequests'] as num?)?.toInt() ?? 0,
        lastSeenMillis: (json['lastSeenMillis'] as num?)?.toInt() ?? 0,
        connectionStatus: (json['connectionStatus'] as String?) ?? 'available',
      );

  PeerInfo copyWith({
    String? peerId,
    String? deviceName,
    String? platform,
    String? ip,
    int? httpPort,
    int? webSocketPort,
    Set<int>? availableChunks,
    double? emaThroughput,
    double? successRate,
    int? activeRequests,
    int? lastSeenMillis,
    String? connectionStatus,
  }) {
    return PeerInfo(
      peerId: peerId ?? this.peerId,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      ip: ip ?? this.ip,
      httpPort: httpPort ?? this.httpPort,
      webSocketPort: webSocketPort ?? this.webSocketPort,
      availableChunks: availableChunks ?? Set.from(this.availableChunks),
      emaThroughput: emaThroughput ?? this.emaThroughput,
      successRate: successRate ?? this.successRate,
      activeRequests: activeRequests ?? this.activeRequests,
      lastSeenMillis: lastSeenMillis ?? this.lastSeenMillis,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }
}
