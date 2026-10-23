import 'dart:async';
import '../models/peer.dart';

/// Manages the swarm's live peer state, connection health, and chunk availability map.
class PeerManager {
  static final PeerManager _instance = PeerManager._internal();
  factory PeerManager() => _instance;
  PeerManager._internal();

  final Map<String, PeerInfo> _peers = {};
  final _peersController = StreamController<List<PeerInfo>>.broadcast();
  Timer? _pruneTimer;

  Stream<List<PeerInfo>> get peersStream => _peersController.stream;
  List<PeerInfo> get activePeers => List.unmodifiable(_peers.values.where((p) => p.connectionStatus != 'disconnected'));

  void init() {
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkPeerHealth());
  }

  /// Adds or updates a peer in the swarm.
  void addOrUpdatePeer(PeerInfo peer) {
    peer.touch();
    final existing = _peers[peer.peerId];
    if (existing != null) {
      existing.touch();
      existing.connectionStatus = 'available';
      if (peer.availableChunks.isNotEmpty) {
        existing.availableChunks.addAll(peer.availableChunks);
      }
    } else {
      _peers[peer.peerId] = peer;
    }
    _notify();
  }

  /// Updates the verified chunks known to be available on a specific peer.
  void updatePeerChunks(String peerId, Set<int> chunks) {
    final peer = _peers[peerId];
    if (peer != null) {
      peer.availableChunks.addAll(chunks);
      peer.touch();
      _notify();
    }
  }

  /// Marks a single chunk as available on a specific peer.
  void addPeerChunk(String peerId, int chunkId) {
    final peer = _peers[peerId];
    if (peer != null) {
      peer.availableChunks.add(chunkId);
      peer.touch();
      _notify();
    }
  }

  PeerInfo? getPeer(String peerId) => _peers[peerId];

  void removePeer(String peerId) {
    _peers.remove(peerId);
    _notify();
  }

  void _checkPeerHealth() {
    final now = DateTime.now().millisecondsSinceEpoch;
    bool changed = false;

    for (final peer in _peers.values) {
      final elapsed = now - peer.lastSeenMillis;
      if (elapsed > 20000 && peer.connectionStatus != 'disconnected') {
        peer.connectionStatus = 'disconnected';
        changed = true;
      } else if (elapsed > 10000 && peer.connectionStatus == 'available') {
        peer.connectionStatus = 'stale';
        changed = true;
      }
    }

    if (changed) {
      _notify();
    }
  }

  void _notify() {
    _peersController.add(activePeers);
  }

  void clear() {
    _peers.clear();
    _notify();
  }

  void dispose() {
    _pruneTimer?.cancel();
    _peersController.close();
  }
}
