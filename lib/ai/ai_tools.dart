import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../metrics/metrics_collector.dart';
import '../models/models.dart';
import '../network/local_server.dart';
import '../repositories/device_repository.dart';
import '../repositories/transfer_repository.dart';

/// Structured, non-hallucinatory tools that retrieve verified live data from FLUXSHARE.
class AITools {
  static final TransferRepository _transferRepo = TransferRepository();
  static final MetricsCollector _metricsCollector = MetricsCollector();
  static final DeviceRepository _deviceRepo = DeviceRepository();
  static final LocalServer _localServer = LocalServer();

  /// Tool 1: get_transfer_history()
  /// Returns records of completed, failed, and cancelled transfers.
  static Future<List<Map<String, dynamic>>> getTransferHistory({int limit = 20}) async {
    final history = await _transferRepo.getTransferHistory();
    return history.take(limit).map((t) {
      return {
        'id': t.id,
        'fileName': t.fileInfo.name,
        'size': t.fileInfo.formattedSize,
        'sizeBytes': t.fileInfo.sizeBytes,
        'direction': t.direction.name,
        'status': t.status.name,
        'speedMbPerSec': t.transferSpeedMbPerSec,
        'timestamp': t.timestamp.toIso8601String(),
        'receiversCount': t.receivers.length,
      };
    }).toList();
  }

  /// Tool 2: get_active_transfers()
  /// Returns all in-flight file transfers.
  static Future<List<Map<String, dynamic>>> getActiveTransfers() async {
    final active = await _transferRepo.getActiveTransfers();
    return active.map((t) {
      return {
        'id': t.id,
        'fileName': t.fileInfo.name,
        'progressPercent': t.progressPercent,
        'bytesTransferred': t.bytesTransferred,
        'totalBytes': t.fileInfo.sizeBytes,
        'speedMbPerSec': t.transferSpeedMbPerSec,
        'remainingSeconds': t.remainingSeconds,
        'status': t.status.name,
        'direction': t.direction.name,
      };
    }).toList();
  }

  /// Tool 3: get_failed_transfers()
  /// Returns transfers that experienced failures along with error diagnostics.
  static Future<List<Map<String, dynamic>>> getFailedTransfers() async {
    final history = await _transferRepo.getTransferHistory();
    final failed = history.where((t) => t.status == TransferStatus.failed).toList();
    return failed.map((t) {
      return {
        'id': t.id,
        'fileName': t.fileInfo.name,
        'size': t.fileInfo.formattedSize,
        'timestamp': t.timestamp.toIso8601String(),
        'status': t.status.name,
        'chunkStats': t.chunkStats,
      };
    }).toList();
  }

  /// Tool 4: get_file_metadata()
  /// Looks up specific metadata of a transfer or file by ID or filename substring.
  static Future<Map<String, dynamic>?> getFileMetadata(String fileIdOrName) async {
    final active = await _transferRepo.getActiveTransfers();
    final history = await _transferRepo.getTransferHistory();
    final all = [...active, ...history];

    final match = all.cast<Transfer?>().firstWhere(
      (t) =>
          t!.id == fileIdOrName ||
          t.fileInfo.name.toLowerCase().contains(fileIdOrName.toLowerCase()),
      orElse: () => null,
    );

    if (match == null) return null;

    return {
      'id': match.id,
      'fileName': match.fileInfo.name,
      'extension': match.fileInfo.extension,
      'type': match.fileInfo.type.displayName,
      'sizeBytes': match.fileInfo.sizeBytes,
      'formattedSize': match.fileInfo.formattedSize,
      'status': match.status.name,
      'direction': match.direction.name,
      'speedMbPerSec': match.transferSpeedMbPerSec,
      'timestamp': match.timestamp.toIso8601String(),
      'receivers': match.receivers.map((r) => r.toMap()).toList(),
    };
  }

  /// Tool 5: get_network_statistics()
  /// Retrieves local server ports, peer identity, and active connection status.
  static Future<Map<String, dynamic>> getNetworkStatistics() async {
    final activeTransfers = await _transferRepo.getActiveTransfers();
    final devices = await _deviceRepo.getNearbyDevices();

    return {
      'localPeerId': _localServer.localPeerId,
      'localDeviceName': _localServer.localDeviceName,
      'platform': _localServer.platform,
      'serverPort': 8080,
      'activeTransfersCount': activeTransfers.length,
      'discoveredNearbyDevicesCount': devices.length,
      'activeControlSockets': _localServer.activeControlSocketsCount,
    };
  }

  /// Tool 6: get_transfer_statistics()
  /// Computes cumulative performance metrics (speeds, volumes, retries).
  static Future<Map<String, dynamic>> getTransferStatistics() async {
    final history = await _transferRepo.getTransferHistory();
    final metricsHistory = _metricsCollector.getHistory();

    int totalSentBytes = 0;
    int totalReceivedBytes = 0;
    int completedCount = 0;
    int failedCount = 0;
    double speedSum = 0.0;
    int speedSamples = 0;

    for (final t in history) {
      if (t.status == TransferStatus.completed) {
        completedCount++;
        if (t.direction == TransferDirection.sent) {
          totalSentBytes += t.fileInfo.sizeBytes;
        } else {
          totalReceivedBytes += t.fileInfo.sizeBytes;
        }
        if (t.transferSpeedMbPerSec > 0) {
          speedSum += t.transferSpeedMbPerSec;
          speedSamples++;
        }
      } else if (t.status == TransferStatus.failed) {
        failedCount++;
      }
    }

    int totalRetransmissions = 0;
    for (final m in metricsHistory) {
      totalRetransmissions += m.retransmissionCount;
    }

    final avgSpeed = speedSamples > 0 ? (speedSum / speedSamples) : 0.0;

    return {
      'totalTransfers': history.length,
      'completedTransfers': completedCount,
      'failedTransfers': failedCount,
      'totalSentBytes': totalSentBytes,
      'totalReceivedBytes': totalReceivedBytes,
      'totalSentFormatted': _formatBytes(totalSentBytes),
      'totalReceivedFormatted': _formatBytes(totalReceivedBytes),
      'averageThroughputMbPerSec': double.parse(avgSpeed.toStringAsFixed(2)),
      'totalRetransmissions': totalRetransmissions,
    };
  }

  /// Tool 7: get_peer_information()
  /// Details of discovered and connected peer devices.
  static Future<List<Map<String, dynamic>>> getPeerInformation() async {
    final devices = await _deviceRepo.getNearbyDevices();
    return devices.map((d) {
      return {
        'id': d.id,
        'name': d.name,
        'ip': d.ip,
        'platform': d.platform,
        'isAvailable': d.isAvailable,
        'signalStrength': d.signalStrength,
      };
    }).toList();
  }

  /// Tool 8: get_storage_statistics()
  /// Analyzes local directory footprint and received files volume.
  static Future<Map<String, dynamic>> getStorageStatistics() async {
    int totalBytes = 0;
    int fileCount = 0;
    String folderPath = '';

    try {
      final docDir = await getApplicationDocumentsDirectory();
      folderPath = '${docDir.path}/FluxShare';
      final dir = Directory(folderPath);
      if (await dir.exists()) {
        final entities = dir.listSync(recursive: true);
        for (final entity in entities) {
          if (entity is File) {
            totalBytes += entity.lengthSync();
            fileCount++;
          }
        }
      }
    } catch (_) {}

    // Cross-reference with completed received files
    final history = await _transferRepo.getTransferHistory();
    int receivedHistoryBytes = 0;
    int receivedCount = 0;

    for (final t in history) {
      if (t.direction == TransferDirection.received && t.status == TransferStatus.completed) {
        receivedHistoryBytes += t.fileInfo.sizeBytes;
        receivedCount++;
      }
    }

    return {
      'downloadFolderPath': folderPath,
      'localFilesCount': fileCount > 0 ? fileCount : receivedCount,
      'totalStorageUsedBytes': totalBytes > 0 ? totalBytes : receivedHistoryBytes,
      'totalStorageUsedFormatted': _formatBytes(totalBytes > 0 ? totalBytes : receivedHistoryBytes),
      'receivedTransfersCount': receivedCount,
    };
  }

  /// Dispatches tool calls dynamically by name.
  static Future<dynamic> executeTool(String toolName, [Map<String, dynamic>? arguments]) async {
    switch (toolName) {
      case 'get_transfer_history':
        final limit = (arguments?['limit'] as num?)?.toInt() ?? 20;
        return await getTransferHistory(limit: limit);
      case 'get_active_transfers':
        return await getActiveTransfers();
      case 'get_failed_transfers':
        return await getFailedTransfers();
      case 'get_file_metadata':
        final query = arguments?['fileIdOrName'] as String? ?? '';
        return await getFileMetadata(query);
      case 'get_network_statistics':
        return await getNetworkStatistics();
      case 'get_transfer_statistics':
        return await getTransferStatistics();
      case 'get_peer_information':
        return await getPeerInformation();
      case 'get_storage_statistics':
        return await getStorageStatistics();
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
