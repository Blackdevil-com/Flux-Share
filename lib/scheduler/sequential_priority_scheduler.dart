import '../models/peer.dart';
import 'chunk_scheduler.dart';

/// Sequential-priority chunk scheduler.
/// Prioritizes earliest missing chunks in file order (e.g. for media streaming / fast preview)
/// within a configurable priority window, falling back seamlessly to normal scheduling
/// when priority chunks are completed, unavailable, or in-flight.
class SequentialPriorityScheduler implements ChunkScheduler {
  final int priorityWindowSize;
  final ChunkScheduler fallbackScheduler;
  int _cursor = 0;

  SequentialPriorityScheduler({
    this.priorityWindowSize = 5,
    ChunkScheduler? fallbackScheduler,
  }) : fallbackScheduler = fallbackScheduler ?? _DefaultRoundRobinFallback();

  @override
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates) {
    if (missingChunks.isEmpty || candidates.isEmpty) return null;
    final decision = schedule(missingChunks: missingChunks, candidates: candidates);
    return decision?.peer;
  }

  @override
  ScheduledChunk? schedule({
    required Set<int> missingChunks,
    required List<PeerInfo> candidates,
    String? coordinatorPeerId,
  }) {
    if (missingChunks.isEmpty || candidates.isEmpty) return null;

    final sortedMissing = missingChunks.toList()..sort();

    // 1. Inspect early chunks inside priority window [0, priorityWindowSize)
    final priorityCandidates = sortedMissing.take(priorityWindowSize).toList();

    for (final chunkId in priorityCandidates) {
      // Find candidate peers that possess this specific priority chunk
      final holdingPeers = candidates.where((p) {
        if (p.connectionStatus == 'disconnected') return false;
        return p.availableChunks.contains(chunkId) || p.peerId == coordinatorPeerId;
      }).toList();

      if (holdingPeers.isNotEmpty) {
        // Distribute load among peers holding this chunk
        final peer = holdingPeers[_cursor % holdingPeers.length];
        _cursor++;
        return ScheduledChunk(chunkId: chunkId, peer: peer);
      }
    }

    // 2. If early chunks in priority window are unavailable or blocked,
    // examine remaining missing chunks in file order so transfer does not stall
    for (final chunkId in sortedMissing.skip(priorityWindowSize)) {
      final holdingPeers = candidates.where((p) {
        if (p.connectionStatus == 'disconnected') return false;
        return p.availableChunks.contains(chunkId) || p.peerId == coordinatorPeerId;
      }).toList();

      if (holdingPeers.isNotEmpty) {
        final peer = holdingPeers[_cursor % holdingPeers.length];
        _cursor++;
        return ScheduledChunk(chunkId: chunkId, peer: peer);
      }
    }

    // 3. Fallback to candidate holding any missing chunk
    return fallbackScheduler.schedule(
      missingChunks: missingChunks,
      candidates: candidates,
      coordinatorPeerId: coordinatorPeerId,
    );
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
    fallbackScheduler.recordTransferResult(
      peerId: peerId,
      chunkId: chunkId,
      success: success,
      bytesTransferred: bytesTransferred,
      duration: duration,
      errorMessage: errorMessage,
    );
  }
}

class _DefaultRoundRobinFallback implements ChunkScheduler {
  int _cursor = 0;

  @override
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates) {
    if (candidates.isEmpty || missingChunks.isEmpty) return null;
    final n = candidates.length;
    for (int i = 0; i < n; i++) {
      final idx = (_cursor + i) % n;
      final candidate = candidates[idx];
      if (candidate.connectionStatus == 'disconnected') continue;
      if (candidate.availableChunks.any((c) => missingChunks.contains(c))) {
        _cursor = (idx + 1) % n;
        return candidate;
      }
    }
    return null;
  }

  @override
  ScheduledChunk? schedule({
    required Set<int> missingChunks,
    required List<PeerInfo> candidates,
    String? coordinatorPeerId,
  }) {
    final peer = selectSource(missingChunks, candidates);
    if (peer == null) return null;
    final chunkId = missingChunks.firstWhere(
      (id) => peer.availableChunks.contains(id) || peer.peerId == coordinatorPeerId,
      orElse: () => missingChunks.first,
    );
    return ScheduledChunk(chunkId: chunkId, peer: peer);
  }

  @override
  void recordTransferResult({
    required String peerId,
    required int chunkId,
    required bool success,
    required int bytesTransferred,
    required Duration duration,
    String? errorMessage,
  }) {}
}
