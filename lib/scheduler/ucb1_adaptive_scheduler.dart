import 'dart:math';
import '../models/peer.dart';
import 'chunk_scheduler.dart';

class PeerUCBStats {
  final String peerId;
  int observations = 0;
  double cumulativeReward = 0.0;
  double lastRecordedThroughput = 0.0;

  PeerUCBStats(this.peerId);

  double get meanReward => observations > 0 ? (cumulativeReward / observations) : 0.0;
}

/// Multi-Armed Bandit (MAB) chunk scheduler implementing the UCB1 algorithm:
/// UCB(peer) = meanReward(peer) + c * sqrt(ln(N) / n(peer))
///
/// Rewards are based on normalized measured throughput (MB/s).
/// Unseen peers receive an exploration boost (+infinity) to guarantee fair initial trials.
class UCB1AdaptiveScheduler implements ChunkScheduler {
  final double explorationConstant; // c (default sqrt(2) ~ 1.414)
  final double referenceThroughputMbPerSec; // Normalization ceiling (e.g. 40 MB/s)
  final double failurePenalty; // Penalty reward on failure (default 0.0)

  final Map<String, PeerUCBStats> _stats = {};
  int _totalObservations = 0;

  UCB1AdaptiveScheduler({
    this.explorationConstant = 1.41421356,
    this.referenceThroughputMbPerSec = 40.0,
    this.failurePenalty = 0.0,
  });

  int get totalObservations => _totalObservations;
  Map<String, PeerUCBStats> get peerStats => Map.unmodifiable(_stats);

  PeerUCBStats _getStats(String peerId) {
    return _stats.putIfAbsent(peerId, () => PeerUCBStats(peerId));
  }

  /// Calculates the UCB score for a candidate peer.
  double calculateUCBScore(String peerId) {
    final s = _getStats(peerId);
    if (s.observations == 0) {
      return double.infinity; // Prioritize exploration of unseen peers
    }
    if (_totalObservations <= 0) {
      return s.meanReward;
    }

    final exploitation = s.meanReward;
    final exploration = explorationConstant * sqrt(log(_totalObservations) / s.observations);
    return exploitation + exploration;
  }

  @override
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates) {
    if (missingChunks.isEmpty || candidates.isEmpty) return null;

    // Filter to connected candidates that hold at least one missing chunk
    final eligible = candidates.where((p) {
      if (p.connectionStatus == 'disconnected') return false;
      return p.availableChunks.any((c) => missingChunks.contains(c));
    }).toList();

    if (eligible.isEmpty) return null;

    PeerInfo? bestPeer;
    double bestScore = -double.infinity;

    for (final peer in eligible) {
      final score = calculateUCBScore(peer.peerId);
      if (score > bestScore) {
        bestScore = score;
        bestPeer = peer;
      }
    }

    return bestPeer;
  }

  @override
  ScheduledChunk? schedule({
    required Set<int> missingChunks,
    required List<PeerInfo> candidates,
    String? coordinatorPeerId,
  }) {
    if (missingChunks.isEmpty || candidates.isEmpty) return null;

    // Filter to connected peers holding missing chunks or coordinator
    final eligible = candidates.where((p) {
      if (p.connectionStatus == 'disconnected') return false;
      return p.availableChunks.any((c) => missingChunks.contains(c)) || p.peerId == coordinatorPeerId;
    }).toList();

    if (eligible.isEmpty) return null;

    PeerInfo? bestPeer;
    double bestScore = -double.infinity;

    for (final peer in eligible) {
      final score = calculateUCBScore(peer.peerId);
      if (score > bestScore) {
        bestScore = score;
        bestPeer = peer;
      }
    }

    final selectedPeer = bestPeer;
    if (selectedPeer == null) return null;

    final targetChunkId = missingChunks.firstWhere(
      (id) => selectedPeer.availableChunks.contains(id) || selectedPeer.peerId == coordinatorPeerId,
      orElse: () => missingChunks.first,
    );

    return ScheduledChunk(chunkId: targetChunkId, peer: selectedPeer);
  }

  @override
  void recordTransferResult({
    required String peerId,
    required int chunkId,
    required bool success,
    required int bytesTransferred,
    required Duration duration,
    String? errorMessage,
  }) {
    final s = _getStats(peerId);
    _totalObservations++;
    s.observations++;

    if (!success) {
      s.cumulativeReward += failurePenalty;
      return;
    }

    final seconds = duration.inMicroseconds / 1000000.0;
    if (seconds <= 0 || bytesTransferred <= 0) {
      // Invalid sample; treat conservatively
      s.cumulativeReward += 0.1;
      return;
    }

    final speedMbPerSec = (bytesTransferred / (1024 * 1024)) / seconds;
    s.lastRecordedThroughput = speedMbPerSec;

    // Normalized reward clamped to [0.0, 1.0]
    final normalized = (speedMbPerSec / referenceThroughputMbPerSec).clamp(0.0, 1.0);
    s.cumulativeReward += normalized;
  }

  void reset() {
    _stats.clear();
    _totalObservations = 0;
  }
}
