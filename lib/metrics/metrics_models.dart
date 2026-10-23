/// Data models for research evaluation metrics (Part 6, Part 8 & Part 9).
class PeerUtilization {
  final String peerId;
  final String role; // coordinator, receiver, forwarder
  final int bytesReceived;
  final int bytesUploaded;
  final int activeDurationMillis;
  final double utilizationFraction; // activeDuration / totalDuration

  const PeerUtilization({
    required this.peerId,
    required this.role,
    required this.bytesReceived,
    required this.bytesUploaded,
    required this.activeDurationMillis,
    required this.utilizationFraction,
  });

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'role': role,
    'bytesReceived': bytesReceived,
    'bytesUploaded': bytesUploaded,
    'activeDurationMillis': activeDurationMillis,
    'utilizationFraction': utilizationFraction,
  };

  factory PeerUtilization.fromJson(Map<String, dynamic> json) => PeerUtilization(
    peerId: json['peerId'] ?? '',
    role: json['role'] ?? '',
    bytesReceived: json['bytesReceived'] ?? 0,
    bytesUploaded: json['bytesUploaded'] ?? 0,
    activeDurationMillis: json['activeDurationMillis'] ?? 0,
    utilizationFraction: (json['utilizationFraction'] as num?)?.toDouble() ?? 0.0,
  );
}

class RetryEvent {
  final int chunkId;
  final String failedPeerId;
  final String? retriedPeerId;
  final String reason;
  final int timestampMillis;

  const RetryEvent({
    required this.chunkId,
    required this.failedPeerId,
    this.retriedPeerId,
    required this.reason,
    required this.timestampMillis,
  });

  Map<String, dynamic> toJson() => {
    'chunkId': chunkId,
    'failedPeerId': failedPeerId,
    'retriedPeerId': retriedPeerId,
    'reason': reason,
    'timestampMillis': timestampMillis,
  };

  factory RetryEvent.fromJson(Map<String, dynamic> json) => RetryEvent(
    chunkId: json['chunkId'] ?? 0,
    failedPeerId: json['failedPeerId'] ?? '',
    retriedPeerId: json['retriedPeerId'] as String?,
    reason: json['reason'] ?? '',
    timestampMillis: json['timestampMillis'] ?? 0,
  );
}

class TransferMetrics {
  final String transferId;
  final String fileId;
  final String fileName;
  final int fileSize;
  final int chunkCount;
  final int chunkSize;
  final String schedulerMode; // "round-robin", "sequential-priority", "ucb1-adaptive"
  final String networkMode; // "wifi", "hotspot"
  final int receiverCount;

  final int startTimeMillis;
  final int endTimeMillis;
  final int totalDistributionTimeMillis;
  final double aggregateThroughputBytesPerSec;
  final double aggregateThroughputMbps;

  final int senderUploadVolumeBytes;
  final int cooperativeForwardingVolumeBytes;
  final double cooperativeRatio; // cooperative / totalBytes

  final int retransmissionCount;
  final Map<String, PeerUtilization> peerUtilizations;

  // Extended transport metrics (Part 8)
  final Map<String, List<int>> peerConcurrencyHistory;
  final List<RetryEvent> retryEvents;
  final Map<int, int> timeToFirstByteMillis;
  final double avgTimeToFirstByteMillis;
  final int? timeToFirstPreviewReadyMillis;

  const TransferMetrics({
    required this.transferId,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.chunkCount,
    required this.chunkSize,
    required this.schedulerMode,
    this.networkMode = 'wifi',
    required this.receiverCount,
    required this.startTimeMillis,
    required this.endTimeMillis,
    required this.totalDistributionTimeMillis,
    required this.aggregateThroughputBytesPerSec,
    required this.aggregateThroughputMbps,
    required this.senderUploadVolumeBytes,
    required this.cooperativeForwardingVolumeBytes,
    required this.cooperativeRatio,
    required this.retransmissionCount,
    required this.peerUtilizations,
    this.peerConcurrencyHistory = const {},
    this.retryEvents = const [],
    this.timeToFirstByteMillis = const {},
    this.avgTimeToFirstByteMillis = 0.0,
    this.timeToFirstPreviewReadyMillis,
  });

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileId': fileId,
    'fileName': fileName,
    'fileSize': fileSize,
    'chunkCount': chunkCount,
    'chunkSize': chunkSize,
    'schedulerMode': schedulerMode,
    'networkMode': networkMode,
    'receiverCount': receiverCount,
    'startTimeMillis': startTimeMillis,
    'endTimeMillis': endTimeMillis,
    'totalDistributionTimeMillis': totalDistributionTimeMillis,
    'aggregateThroughputBytesPerSec': aggregateThroughputBytesPerSec,
    'aggregateThroughputMbps': aggregateThroughputMbps,
    'senderUploadVolumeBytes': senderUploadVolumeBytes,
    'cooperativeForwardingVolumeBytes': cooperativeForwardingVolumeBytes,
    'cooperativeRatio': cooperativeRatio,
    'retransmissionCount': retransmissionCount,
    'peerUtilizations': peerUtilizations.map((k, v) => MapEntry(k, v.toJson())),
    'peerConcurrencyHistory': peerConcurrencyHistory,
    'retryEvents': retryEvents.map((r) => r.toJson()).toList(),
    'timeToFirstByteMillis': timeToFirstByteMillis.map((k, v) => MapEntry(k.toString(), v)),
    'avgTimeToFirstByteMillis': avgTimeToFirstByteMillis,
    'timeToFirstPreviewReadyMillis': timeToFirstPreviewReadyMillis,
  };

  factory TransferMetrics.fromJson(Map<String, dynamic> json) => TransferMetrics(
    transferId: json['transferId'] ?? '',
    fileId: json['fileId'] ?? '',
    fileName: json['fileName'] ?? '',
    fileSize: json['fileSize'] ?? 0,
    chunkCount: json['chunkCount'] ?? 0,
    chunkSize: json['chunkSize'] ?? 0,
    schedulerMode: json['schedulerMode'] ?? 'round-robin',
    networkMode: json['networkMode'] ?? 'wifi',
    receiverCount: json['receiverCount'] ?? 0,
    startTimeMillis: json['startTimeMillis'] ?? 0,
    endTimeMillis: json['endTimeMillis'] ?? 0,
    totalDistributionTimeMillis: json['totalDistributionTimeMillis'] ?? 0,
    aggregateThroughputBytesPerSec: (json['aggregateThroughputBytesPerSec'] as num?)?.toDouble() ?? 0.0,
    aggregateThroughputMbps: (json['aggregateThroughputMbps'] as num?)?.toDouble() ?? 0.0,
    senderUploadVolumeBytes: json['senderUploadVolumeBytes'] ?? 0,
    cooperativeForwardingVolumeBytes: json['cooperativeForwardingVolumeBytes'] ?? 0,
    cooperativeRatio: (json['cooperativeRatio'] as num?)?.toDouble() ?? 0.0,
    retransmissionCount: json['retransmissionCount'] ?? 0,
    peerUtilizations: (json['peerUtilizations'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, PeerUtilization.fromJson(v as Map<String, dynamic>)),
        ) ??
        {},
    peerConcurrencyHistory: (json['peerConcurrencyHistory'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, (v as List<dynamic>).map((e) => (e as num).toInt()).toList()),
        ) ??
        {},
    retryEvents: (json['retryEvents'] as List<dynamic>?)
            ?.map((e) => RetryEvent.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    timeToFirstByteMillis: (json['timeToFirstByteMillis'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(int.tryParse(k) ?? 0, (v as num).toInt()),
        ) ??
        {},
    avgTimeToFirstByteMillis: (json['avgTimeToFirstByteMillis'] as num?)?.toDouble() ?? 0.0,
    timeToFirstPreviewReadyMillis: json['timeToFirstPreviewReadyMillis'] as int?,
  );
}
