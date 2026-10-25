import 'dart:async';
import 'dart:math';
import '../models/batch_manifest.dart';
import '../models/manifest.dart';
import '../models/peer.dart';

enum RoomState {
  created,
  open,
  distributing,
  completed,
  expired,
}

class RoomSession {
  final String roomId;
  final String pin;
  final String hostPeerId;
  final String hostDeviceName;
  final DateTime createdAt;
  RoomState state;
  Manifest? manifest;
  BatchManifest? batchManifest;
  final Map<String, PeerInfo> joinedPeers = {};

  RoomSession({
    required this.roomId,
    required this.pin,
    required this.hostPeerId,
    required this.hostDeviceName,
    required this.createdAt,
    this.state = RoomState.created,
    this.manifest,
    this.batchManifest,
  });

  Map<String, dynamic> toJson() => {
    'roomId': roomId,
    'pin': pin,
    'hostPeerId': hostPeerId,
    'hostDeviceName': hostDeviceName,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
    'joinedPeers': joinedPeers.values.map((p) => p.toJson()).toList(),
    'manifest': manifest?.toJson(),
    'batchManifest': batchManifest?.toJson(),
  };
}

/// Manages the room lifecycle and peer membership for local cooperative file transfers.
class RoomManager {
  static final RoomManager _instance = RoomManager._internal();
  factory RoomManager() => _instance;
  RoomManager._internal();

  RoomSession? _currentRoom;
  final _roomStateController = StreamController<RoomSession?>.broadcast();

  RoomSession? get currentRoom => _currentRoom;
  Stream<RoomSession?> get roomStream => _roomStateController.stream;

  /// Generates a random 6-digit PIN.
  static String generatePin() {
    final random = Random.secure();
    return (100000 + random.nextInt(900000)).toString();
  }

  /// Creates a new room as coordinator.
  RoomSession createRoom({
    required String hostPeerId,
    required String hostDeviceName,
    String? customPin,
    Manifest? manifest,
    BatchManifest? batchManifest,
  }) {
    final pin = customPin ?? generatePin();
    final roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';

    final room = RoomSession(
      roomId: roomId,
      pin: pin,
      hostPeerId: hostPeerId,
      hostDeviceName: hostDeviceName,
      createdAt: DateTime.now(),
      state: RoomState.created,
      manifest: manifest,
      batchManifest: batchManifest,
    );

    _currentRoom = room;
    _roomStateController.add(_currentRoom);
    return room;
  }

  /// Opens the room for receiver discovery and connection.
  void openRoom() {
    if (_currentRoom != null) {
      _currentRoom!.state = RoomState.open;
      _roomStateController.add(_currentRoom);
    }
  }

  /// Transitions room to active distribution state.
  void startDistribution() {
    if (_currentRoom != null) {
      _currentRoom!.state = RoomState.distributing;
      _roomStateController.add(_currentRoom);
    }
  }

  /// Registers a peer into the active room if the PIN matches.
  bool registerPeer(PeerInfo peer, String pin) {
    if (_currentRoom == null) return false;
    if (_currentRoom!.pin != pin) return false;
    if (_currentRoom!.state == RoomState.expired) return false;

    _currentRoom!.joinedPeers[peer.peerId] = peer;
    _roomStateController.add(_currentRoom);
    return true;
  }

  /// Removes a peer from the active room.
  void removePeer(String peerId) {
    if (_currentRoom != null) {
      _currentRoom!.joinedPeers.remove(peerId);
      _roomStateController.add(_currentRoom);
    }
  }

  /// Completes the room transfer session.
  void completeRoom() {
    if (_currentRoom != null) {
      _currentRoom!.state = RoomState.completed;
      _roomStateController.add(_currentRoom);
    }
  }

  /// Expires and cleans up the active room.
  void expireRoom() {
    if (_currentRoom != null) {
      _currentRoom!.state = RoomState.expired;
      _roomStateController.add(_currentRoom);
      _currentRoom = null;
    }
  }
}
