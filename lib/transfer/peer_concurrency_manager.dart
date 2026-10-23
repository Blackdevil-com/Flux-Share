import 'dart:math';
import '../models/peer.dart';

class PeerConcurrencyState {
  final String peerId;
  int allowedConcurrency;
  int inFlightCount;
  int consecutiveFailures;
  int successStreak;
  int cooldownUntilMillis;

  PeerConcurrencyState({
    required this.peerId,
    this.allowedConcurrency = 2,
    this.inFlightCount = 0,
    this.consecutiveFailures = 0,
    this.successStreak = 0,
    this.cooldownUntilMillis = 0,
  });
}

/// Transport-layer AIMD congestion control & cooldown manager.
/// Adjusts per-peer in-flight limits adaptively without touching peer-selection scoring.
class PeerConcurrencyManager {
  final Map<String, PeerConcurrencyState> _peerStates = {};
  final int minConcurrency;
  final int maxConcurrency;
  final int failureCooldownThreshold;
  final Duration cooldownDuration;

  PeerConcurrencyManager({
    this.minConcurrency = 1,
    this.maxConcurrency = 8,
    this.failureCooldownThreshold = 3,
    this.cooldownDuration = const Duration(seconds: 10),
  });

  PeerConcurrencyState _getState(String peerId) {
    return _peerStates.putIfAbsent(
      peerId,
      () => PeerConcurrencyState(peerId: peerId),
    );
  }

  /// Returns true if a new chunk request can be assigned to [peerId].
  bool canRequestFrom(String peerId) {
    final state = _getState(peerId);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (now < state.cooldownUntilMillis) {
      return false; // In cooldown period
    }

    return state.inFlightCount < state.allowedConcurrency;
  }

  /// Filters candidate peers to only those with capacity and not in cooldown.
  List<PeerInfo> filterAvailableCandidates(List<PeerInfo> peers) {
    return peers.where((p) {
      if (p.connectionStatus == 'disconnected') return false;
      return canRequestFrom(p.peerId);
    }).toList();
  }

  /// Marks a chunk download in flight.
  void markRequestStarted(String peerId) {
    final state = _getState(peerId);
    state.inFlightCount++;
  }

  /// Handles successful chunk delivery: Additive Increase.
  void markRequestSuccess(String peerId) {
    final state = _getState(peerId);
    state.inFlightCount = max(0, state.inFlightCount - 1);
    state.consecutiveFailures = 0;
    state.successStreak++;

    // Additive Increase: increase allowed concurrency after 2 consecutive fast chunk deliveries
    if (state.successStreak >= 2) {
      state.allowedConcurrency = min(maxConcurrency, state.allowedConcurrency + 1);
      state.successStreak = 0;
    }
  }

  /// Handles chunk request failure/timeout: Multiplicative Decrease & Cooldown check.
  void markRequestFailure(String peerId) {
    final state = _getState(peerId);
    state.inFlightCount = max(0, state.inFlightCount - 1);
    state.successStreak = 0;

    // Multiplicative Decrease: halve the allowed concurrency limit
    state.allowedConcurrency = max(minConcurrency, state.allowedConcurrency ~/ 2);
    state.consecutiveFailures++;

    if (state.consecutiveFailures >= failureCooldownThreshold) {
      state.cooldownUntilMillis = DateTime.now().millisecondsSinceEpoch + cooldownDuration.inMilliseconds;
      state.consecutiveFailures = 0;
    }
  }

  int getAllowedConcurrency(String peerId) => _getState(peerId).allowedConcurrency;
  int getInFlightCount(String peerId) => _getState(peerId).inFlightCount;

  void reset() {
    _peerStates.clear();
  }
}
