import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Client service managing the WebSocket control connection to the coordinator or swarm.
class WebSocketService {
  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  bool get isConnected => _channel != null;

  /// Connects to host's /ws endpoint supporting both named and positional parameters.
  Future<bool> connect({
    required String hostIp,
    required int port,
    String? localPeerId,
  }) async {
    disconnect();
    final uri = Uri.parse('ws://$hostIp:$port/ws');
    try {
      final channel = WebSocketChannel.connect(uri);
      await channel.ready;
      _channel = channel;

      channel.stream.listen(
        (data) {
          try {
            final parsed = jsonDecode(data as String) as Map<String, dynamic>;
            _messageController.add(parsed);
          } catch (_) {}
        },
        onDone: disconnect,
        onError: (_) => disconnect(),
      );

      // If localPeerId provided, announce join to coordinator
      if (localPeerId != null) {
        send({
          'type': 'PEER_JOIN',
          'peerId': localPeerId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Start 5-second heartbeat
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        send({
          'type': 'HEARTBEAT',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      });

      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }

  /// Backward-compatible positional connect overload
  Future<bool> connectPositional(String hostIp, int hostPort) =>
      connect(hostIp: hostIp, port: hostPort);

  void send(Map<String, dynamic> message) {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode(message));
      } catch (_) {}
    }
  }

  /// Broadcasts that a chunk has been downloaded and verified on disk.
  void notifyChunkAvailable(int chunkId) {
    send({
      'type': 'CHUNK_AVAILABLE',
      'chunkId': chunkId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Broadcasts that transfer finished and all chunks passed Tier 1-3 integrity.
  void notifyTransferCompleted() {
    send({
      'type': 'TRANSFER_COMPLETED',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Broadcasts that transfer has been paused.
  void notifyTransferPaused() {
    send({
      'type': 'TRANSFER_PAUSED',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Broadcasts that transfer has been resumed.
  void notifyTransferResumed() {
    send({
      'type': 'TRANSFER_RESUMED',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Broadcasts that transfer was cancelled by user.
  void notifyTransferCancelled() {
    send({
      'type': 'TRANSFER_CANCELLED',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void sendProgress({
    required String peerId,
    required String fileId,
    required double progress,
    required int bytesTransferred,
    required double speedMBps,
    required int chunksCompleted,
    required int totalChunks,
    required int timeRemainingSeconds,
  }) {
    send({
      'type': 'TRANSFER_PROGRESS',
      'peerId': peerId,
      'fileId': fileId,
      'progress': progress,
      'bytesTransferred': bytesTransferred,
      'speedMBps': speedMBps,
      'chunksCompleted': chunksCompleted,
      'totalChunks': totalChunks,
      'timeRemainingSeconds': timeRemainingSeconds,
    });
  }

  void sendCompleted(String peerId, String fileId) {
    send({
      'type': 'TRANSFER_COMPLETED',
      'peerId': peerId,
      'fileId': fileId,
    });
  }

  void sendFailed(String peerId, String fileId, String error) {
    send({
      'type': 'TRANSFER_FAILED',
      'peerId': peerId,
      'fileId': fileId,
      'errorMessage': error,
    });
  }

  void disconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
