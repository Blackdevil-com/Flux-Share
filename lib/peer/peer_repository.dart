import 'dart:async';
import '../models/peer.dart';
import 'peer_manager.dart';

/// Repository providing access to discovered peers in the cooperative network.
class PeerRepository {
  final PeerManager _peerManager = PeerManager();

  Stream<List<PeerInfo>> get peersStream => _peerManager.peersStream;

  List<PeerInfo> getActivePeers() => _peerManager.activePeers;

  PeerInfo? getPeer(String peerId) => _peerManager.getPeer(peerId);

  void updatePeerChunks(String peerId, Set<int> chunks) {
    _peerManager.updatePeerChunks(peerId, chunks);
  }
}
