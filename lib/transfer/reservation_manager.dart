/// Manages chunk download reservations to prevent multiple workers
/// from redundantly fetching the same chunk concurrently.
class ReservationManager {
  final Map<int, String> _reservations = {}; // chunkId -> workerId
  final Map<int, DateTime> _reservationTimestamps = {};
  final Duration timeout;

  ReservationManager({this.timeout = const Duration(seconds: 30)});

  /// Attempts to reserve a chunk for the specified worker.
  /// Returns true if reserved successfully, false if already reserved by another worker.
  bool tryReserve(int chunkId, String workerId) {
    _cleanExpired();
    if (_reservations.containsKey(chunkId)) {
      return _reservations[chunkId] == workerId;
    }
    _reservations[chunkId] = workerId;
    _reservationTimestamps[chunkId] = DateTime.now();
    return true;
  }

  /// Renews an active reservation for an ongoing download so it does not expire.
  bool renew(int chunkId, String workerId) {
    if (_reservations[chunkId] == workerId) {
      _reservationTimestamps[chunkId] = DateTime.now();
      return true;
    }
    return false;
  }

  /// Releases reservation for the given chunk.
  void release(int chunkId) {
    _reservations.remove(chunkId);
    _reservationTimestamps.remove(chunkId);
  }

  /// Releases all reservations owned by a specific worker.
  void releaseAll(String workerId) {
    final toRemove = <int>[];
    _reservations.forEach((chunkId, holder) {
      if (holder == workerId) {
        toRemove.add(chunkId);
      }
    });
    for (final id in toRemove) {
      _reservations.remove(id);
      _reservationTimestamps.remove(id);
    }
  }

  /// Checks if a chunk is currently reserved.
  bool isReserved(int chunkId) {
    _cleanExpired();
    return _reservations.containsKey(chunkId);
  }

  void _cleanExpired() {
    final now = DateTime.now();
    final expired = <int>[];
    _reservationTimestamps.forEach((chunkId, time) {
      if (now.difference(time) > timeout) {
        expired.add(chunkId);
      }
    });
    for (final id in expired) {
      _reservations.remove(id);
      _reservationTimestamps.remove(id);
    }
  }

  void clear() {
    _reservations.clear();
    _reservationTimestamps.clear();
  }
}
