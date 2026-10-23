import '../models/peer.dart';

class ScheduledChunk {
  final int chunkId;
  final PeerInfo peer;

  const ScheduledChunk({required this.chunkId, required this.peer});
}

/// Abstract chunk scheduling interface.
/// Kept swappable so adaptive/bandit and sequential-priority scheduling can replace round-robin
/// without modifying transfer/networking code.
abstract class ChunkScheduler {
  /// Selects the best peer source holding any of the missing chunks.
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates);

  /// Selects the next chunk and peer assignment, or returns null if none can be scheduled.
  /// Default implementation uses [selectSource] and picks the first missing chunk available on that peer.
  ScheduledChunk? schedule({
    required Set<int> missingChunks,
    required List<PeerInfo> candidates,
    String? coordinatorPeerId,
  }) {
    if (missingChunks.isEmpty || candidates.isEmpty) return null;
    final peer = selectSource(missingChunks, candidates);
    if (peer == null) return null;

    final targetChunkId = missingChunks.firstWhere(
      (id) => peer.availableChunks.contains(id) || peer.peerId == coordinatorPeerId,
      orElse: () => missingChunks.first,
    );

    return ScheduledChunk(chunkId: targetChunkId, peer: peer);
  }

  /// Optional feedback hook for schedulers that learn or adapt from transfer results (e.g., UCB1).
  void recordTransferResult({
    required String peerId,
    required int chunkId,
    required bool success,
    required int bytesTransferred,
    required Duration duration,
    String? errorMessage,
  }) {}
}
