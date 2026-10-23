import '../models/peer.dart';
import 'chunk_scheduler.dart';

/// Simplest correct implementation of ChunkScheduler.
/// Rotates sequentially through available candidates that hold at least one missing chunk.
class RoundRobinScheduler extends ChunkScheduler {
  int _cursor = 0;

  @override
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates) {
    if (candidates.isEmpty || missingChunks.isEmpty) return null;

    final n = candidates.length;
    for (int i = 0; i < n; i++) {
      final idx = (_cursor + i) % n;
      final candidate = candidates[idx];

      if (candidate.connectionStatus == 'disconnected') continue;

      // Check if this peer holds any of the missing chunks
      final hasMissingChunk = candidate.availableChunks.any((c) => missingChunks.contains(c));
      if (hasMissingChunk) {
        _cursor = (idx + 1) % n;
        return candidate;
      }
    }

    return null;
  }
}
