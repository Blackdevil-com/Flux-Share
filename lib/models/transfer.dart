import 'file_info.dart';
import 'receiver_progress.dart';

enum TransferDirection {
  sent,
  received;

  static TransferDirection fromString(String val) {
    return val.toLowerCase() == 'received'
        ? TransferDirection.received
        : TransferDirection.sent;
  }
}

enum TransferStatus {
  starting,
  transferring,
  paused,
  completed,
  failed,
  cancelled;

  static TransferStatus fromString(String val) {
    switch (val.toLowerCase()) {
      case 'starting':
        return TransferStatus.starting;
      case 'transferring':
        return TransferStatus.transferring;
      case 'paused':
        return TransferStatus.paused;
      case 'completed':
        return TransferStatus.completed;
      case 'failed':
        return TransferStatus.failed;
      case 'cancelled':
        return TransferStatus.cancelled;
      default:
        return TransferStatus.starting;
    }
  }
}

class Transfer {
  final String id;
  final FileInfo fileInfo;
  final TransferDirection direction;
  final TransferStatus status;
  final double progressPercent; // 0 to 100
  final int bytesTransferred;
  final double transferSpeedMbPerSec;
  final int remainingSeconds;
  final DateTime timestamp;
  final List<ReceiverProgress> receivers;
  final Map<String, dynamic> chunkStats;

  const Transfer({
    required this.id,
    required this.fileInfo,
    required this.direction,
    required this.status,
    required this.progressPercent,
    required this.bytesTransferred,
    required this.transferSpeedMbPerSec,
    required this.remainingSeconds,
    required this.timestamp,
    required this.receivers,
    required this.chunkStats,
  });

  Transfer copyWith({
    String? id,
    FileInfo? fileInfo,
    TransferDirection? direction,
    TransferStatus? status,
    double? progressPercent,
    int? bytesTransferred,
    double? transferSpeedMbPerSec,
    int? remainingSeconds,
    DateTime? timestamp,
    List<ReceiverProgress>? receivers,
    Map<String, dynamic>? chunkStats,
  }) {
    return Transfer(
      id: id ?? this.id,
      fileInfo: fileInfo ?? this.fileInfo,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      progressPercent: progressPercent ?? this.progressPercent,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      transferSpeedMbPerSec: transferSpeedMbPerSec ?? this.transferSpeedMbPerSec,
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      timestamp: timestamp ?? this.timestamp,
      receivers: receivers ?? this.receivers,
      chunkStats: chunkStats ?? this.chunkStats,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'fileInfo': fileInfo.toMap(),
      'direction': direction.name,
      'status': status.name,
      'progressPercent': progressPercent,
      'bytesTransferred': bytesTransferred,
      'transferSpeedMbPerSec': transferSpeedMbPerSec,
      'remainingSeconds': remainingSeconds,
      'timestamp': timestamp.toIso8601String(),
      'receivers': receivers.map((r) => r.toMap()).toList(),
      'chunkStats': chunkStats,
    };
  }

  factory Transfer.fromMap(Map<String, dynamic> map) {
    return Transfer(
      id: map['id'] ?? '',
      fileInfo: FileInfo.fromMap(map['fileInfo'] ?? {}),
      direction: TransferDirection.fromString(map['direction'] ?? 'sent'),
      status: TransferStatus.fromString(map['status'] ?? 'starting'),
      progressPercent: (map['progressPercent'] as num?)?.toDouble() ?? 0.0,
      bytesTransferred: map['bytesTransferred'] ?? 0,
      transferSpeedMbPerSec: (map['transferSpeedMbPerSec'] as num?)?.toDouble() ?? 0.0,
      remainingSeconds: map['remainingSeconds'] ?? 0,
      timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      receivers: (map['receivers'] as List<dynamic>?)
              ?.map((r) => ReceiverProgress.fromMap(r as Map<String, dynamic>))
              .toList() ??
          [],
      chunkStats: Map<String, dynamic>.from(map['chunkStats'] ?? {}),
    );
  }
}
