import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'metrics_models.dart';

/// Collects and locally persists research evaluation metrics for transfers.
class MetricsCollector {
  static final MetricsCollector _instance = MetricsCollector._internal();
  factory MetricsCollector() => _instance;
  MetricsCollector._internal();

  String? _activeTransferId;
  String? _fileId;
  String? _fileName;
  int _fileSize = 0;
  int _chunkCount = 0;
  int _chunkSize = 0;
  String _coordinatorPeerId = '';
  String _schedulerMode = 'round-robin';
  int _startTimeMillis = 0;
  int _receiverCount = 0;

  int _senderUploadVolumeBytes = 0;
  int _cooperativeForwardingBytes = 0;
  int _retransmissionCount = 0;

  final Map<String, int> _peerBytesReceived = {};
  final Map<String, int> _peerBytesUploaded = {};
  final Map<String, int> _peerActiveStartMillis = {};
  final Map<String, int> _peerTotalActiveMillis = {};

  // Part 8 Metrics
  final Map<String, List<int>> _peerConcurrencyHistory = {};
  final List<RetryEvent> _retryEvents = [];
  final Map<int, int> _timeToFirstByteMillis = {};

  final List<TransferMetrics> _history = [];
  bool _isInitialized = false;

  /// Initializes persistence and loads stored metrics history.
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final file = await _getStorageFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        _history.clear();
        for (final item in list) {
          _history.add(TransferMetrics.fromJson(item as Map<String, dynamic>));
        }
      }
      _isInitialized = true;
    } catch (_) {
      _isInitialized = true;
    }
  }

  /// Starts recording a new transfer session.
  void startTransfer({
    required String transferId,
    required String fileId,
    required String fileName,
    required int fileSize,
    required int chunkCount,
    required int chunkSize,
    required String coordinatorPeerId,
    required int receiverCount,
    String schedulerMode = 'round-robin',
  }) {
    _activeTransferId = transferId;
    _fileId = fileId;
    _fileName = fileName;
    _fileSize = fileSize;
    _chunkCount = chunkCount;
    _chunkSize = chunkSize;
    _coordinatorPeerId = coordinatorPeerId;
    _receiverCount = receiverCount;
    _schedulerMode = schedulerMode;
    _startTimeMillis = DateTime.now().millisecondsSinceEpoch;

    _senderUploadVolumeBytes = 0;
    _cooperativeForwardingBytes = 0;
    _retransmissionCount = 0;
    _peerBytesReceived.clear();
    _peerBytesUploaded.clear();
    _peerActiveStartMillis.clear();
    _peerTotalActiveMillis.clear();

    _peerConcurrencyHistory.clear();
    _retryEvents.clear();
    _timeToFirstByteMillis.clear();
  }

  /// Records a chunk delivery from a given source peer.
  void recordChunkDelivered({
    required String sourcePeerId,
    required String receiverPeerId,
    required int bytes,
  }) {
    if (sourcePeerId == _coordinatorPeerId) {
      _senderUploadVolumeBytes += bytes;
    } else {
      _cooperativeForwardingBytes += bytes;
    }

    _peerBytesUploaded[sourcePeerId] = (_peerBytesUploaded[sourcePeerId] ?? 0) + bytes;
    _peerBytesReceived[receiverPeerId] = (_peerBytesReceived[receiverPeerId] ?? 0) + bytes;
  }

  /// Records a chunk download failure requiring retransmission.
  void recordRetransmission() {
    _retransmissionCount++;
  }

  /// Records Time To First Byte (TTFB) for handshake & connection latency analysis.
  void recordTimeToFirstByte(int chunkId, int ttfbMillis) {
    _timeToFirstByteMillis[chunkId] = ttfbMillis;
  }

  /// Records retry event with failed peer and retry peer info.
  void recordRetryEvent({
    required int chunkId,
    required String failedPeerId,
    String? retriedPeerId,
    required String reason,
  }) {
    _retryEvents.add(RetryEvent(
      chunkId: chunkId,
      failedPeerId: failedPeerId,
      retriedPeerId: retriedPeerId,
      reason: reason,
      timestampMillis: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Records adaptive concurrency changes over time per peer.
  void recordPeerConcurrency(String peerId, int allowedConcurrency) {
    _peerConcurrencyHistory.putIfAbsent(peerId, () => []).add(allowedConcurrency);
  }

  /// Records active peer work window for utilization calculation.
  void markPeerActive(String peerId) {
    if (!_peerActiveStartMillis.containsKey(peerId)) {
      _peerActiveStartMillis[peerId] = DateTime.now().millisecondsSinceEpoch;
    }
  }

  void markPeerIdle(String peerId) {
    final start = _peerActiveStartMillis.remove(peerId);
    if (start != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - start;
      _peerTotalActiveMillis[peerId] = (_peerTotalActiveMillis[peerId] ?? 0) + elapsed;
    }
  }

  /// Finalizes the active transfer, computes aggregates, and persists to local storage.
  Future<TransferMetrics?> finalizeTransfer() async {
    if (_activeTransferId == null || _startTimeMillis == 0) return null;

    final endTimeMillis = DateTime.now().millisecondsSinceEpoch;
    final totalDuration = endTimeMillis - _startTimeMillis;
    final totalDurationSec = totalDuration / 1000.0;

    final totalDeliveredBytes = _senderUploadVolumeBytes + _cooperativeForwardingBytes;
    final aggregateThroughput = totalDurationSec > 0 ? (totalDeliveredBytes / totalDurationSec) : 0.0;
    final throughputMbps = (aggregateThroughput * 8) / (1000 * 1000);

    final cooperativeRatio = totalDeliveredBytes > 0
        ? (_cooperativeForwardingBytes / totalDeliveredBytes)
        : 0.0;

    // Average TTFB
    double avgTtfb = 0.0;
    if (_timeToFirstByteMillis.isNotEmpty) {
      final sum = _timeToFirstByteMillis.values.reduce((a, b) => a + b);
      avgTtfb = sum / _timeToFirstByteMillis.length;
    }

    // Compile peer utilizations
    final utilizations = <String, PeerUtilization>{};
    final allPeers = <String>{
      ..._peerBytesReceived.keys,
      ..._peerBytesUploaded.keys,
      ..._peerTotalActiveMillis.keys,
      _coordinatorPeerId,
    };

    for (final peerId in allPeers) {
      if (peerId.isEmpty) continue;
      final activeMs = _peerTotalActiveMillis[peerId] ?? 0;
      final utilFraction = totalDuration > 0 ? (activeMs / totalDuration).clamp(0.0, 1.0) : 0.0;
      final role = peerId == _coordinatorPeerId
          ? 'coordinator'
          : (_peerBytesUploaded[peerId] ?? 0) > 0
              ? 'forwarder'
              : 'receiver';

      utilizations[peerId] = PeerUtilization(
        peerId: peerId,
        role: role,
        bytesReceived: _peerBytesReceived[peerId] ?? 0,
        bytesUploaded: _peerBytesUploaded[peerId] ?? 0,
        activeDurationMillis: activeMs,
        utilizationFraction: utilFraction,
      );
    }

    final metrics = TransferMetrics(
      transferId: _activeTransferId!,
      fileId: _fileId ?? '',
      fileName: _fileName ?? '',
      fileSize: _fileSize,
      chunkCount: _chunkCount,
      chunkSize: _chunkSize,
      schedulerMode: _schedulerMode,
      receiverCount: _receiverCount,
      startTimeMillis: _startTimeMillis,
      endTimeMillis: endTimeMillis,
      totalDistributionTimeMillis: totalDuration,
      aggregateThroughputBytesPerSec: aggregateThroughput,
      aggregateThroughputMbps: throughputMbps,
      senderUploadVolumeBytes: _senderUploadVolumeBytes,
      cooperativeForwardingVolumeBytes: _cooperativeForwardingBytes,
      cooperativeRatio: cooperativeRatio,
      retransmissionCount: _retransmissionCount,
      peerUtilizations: utilizations,
      peerConcurrencyHistory: Map.from(_peerConcurrencyHistory),
      retryEvents: List.from(_retryEvents),
      timeToFirstByteMillis: Map.from(_timeToFirstByteMillis),
      avgTimeToFirstByteMillis: avgTtfb,
    );

    _history.add(metrics);
    await _persistHistory();

    _activeTransferId = null;
    return metrics;
  }

  List<TransferMetrics> getHistory() => List.unmodifiable(_history);

  Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/fluxshare_metrics_history.json');
  }

  Future<void> _persistHistory() async {
    try {
      final file = await _getStorageFile();
      final jsonList = _history.map((m) => m.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList), flush: true);
    } catch (_) {}
  }
}
