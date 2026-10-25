/// Canonical PeerInfo model tracking a member in the P2P swarm.
class PeerInfo {
  final String peerId;
  final String deviceName;
  final String platform; // "android" | "ios"
  final String ip;
  final int httpPort;
  final int webSocketPort;
  Set<int> availableChunks; // VERIFIED chunks only
  Map<String, Set<int>> availableChunksByFile;
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
    Map<String, Set<int>>? availableChunksByFile,
    this.emaThroughput = 0.0,
    this.successRate = 1.0,
    this.activeRequests = 0,
    this.lastSeenMillis = 0,
    this.connectionStatus = 'available',
  })  : availableChunks = availableChunks ?? <int>{},
        availableChunksByFile = availableChunksByFile ?? <String, Set<int>>{};

  Set<int> getAvailableChunksForFile(String fileId) {
    final fileChunks = availableChunksByFile[fileId];
    if (fileChunks != null && fileChunks.isNotEmpty) {
      return fileChunks;
    }
    return availableChunks;
  }

  void markChunkAvailableForFile(String fileId, int chunkId) {
    availableChunksByFile.putIfAbsent(fileId, () => <int>{}).add(chunkId);
    availableChunks.add(chunkId);
  }

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
        'availableChunksByFile': availableChunksByFile.map((k, v) => MapEntry(k, v.toList())),
        'emaThroughput': emaThroughput,
        'successRate': successRate,
        'activeRequests': activeRequests,
        'lastSeenMillis': lastSeenMillis,
        'connectionStatus': connectionStatus,
      };

  factory PeerInfo.fromJson(Map<String, dynamic> json) {
    final rawByFile = json['availableChunksByFile'] as Map<String, dynamic>?;
    final chunksByFile = <String, Set<int>>{};
    if (rawByFile != null) {
      rawByFile.forEach((k, v) {
        if (v is List) {
          chunksByFile[k] = v.map((e) => (e as num).toInt()).toSet();
        }
      });
    }

    return PeerInfo(
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
        availableChunksByFile: chunksByFile,
        emaThroughput: (json['emaThroughput'] as num?)?.toDouble() ?? 0.0,
        successRate: (json['successRate'] as num?)?.toDouble() ?? 1.0,
        activeRequests: (json['activeRequests'] as num?)?.toInt() ?? 0,
        lastSeenMillis: (json['lastSeenMillis'] as num?)?.toInt() ?? 0,
        connectionStatus: (json['connectionStatus'] as String?) ?? 'available',
      );
  }

  PeerInfo copyWith({
    String? peerId,
    String? deviceName,
    String? platform,
    String? ip,
    int? httpPort,
    int? webSocketPort,
    Set<int>? availableChunks,
    Map<String, Set<int>>? availableChunksByFile,
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
      availableChunks: availableChunks ?? Set<int>.from(this.availableChunks),
      availableChunksByFile: availableChunksByFile ??
          Map<String, Set<int>>.from(
            this.availableChunksByFile.map((k, v) => MapEntry(k, Set<int>.from(v))),
          ),
      emaThroughput: emaThroughput ?? this.emaThroughput,
      successRate: successRate ?? this.successRate,
      activeRequests: activeRequests ?? this.activeRequests,
      lastSeenMillis: lastSeenMillis ?? this.lastSeenMillis,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }
}
