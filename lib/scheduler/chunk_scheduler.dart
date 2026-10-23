import '../models/peer.dart';

/// Abstract chunk scheduling interface.
/// Kept swappable so adaptive/bandit scheduling can replace round-robin later
/// without modifying transfer/networking code.
abstract class ChunkScheduler {
  /// Selects the best peer source holding any of the missing chunks.
  PeerInfo? selectSource(Set<int> missingChunks, List<PeerInfo> candidates);
}
