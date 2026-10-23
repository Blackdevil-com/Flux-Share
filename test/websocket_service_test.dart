import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/network/websocket_service.dart';

void main() {
  group('WebSocketService Protocol & State Unit Tests', () {
    test('Initializes in disconnected state', () {
      final service = WebSocketService();
      expect(service.isConnected, isFalse);
      service.dispose();
    });

    test('Notification methods execute safely without thrown exceptions when disconnected', () {
      final service = WebSocketService();
      expect(() => service.notifyChunkAvailable(1), returnsNormally);
      expect(() => service.notifyTransferCompleted(), returnsNormally);
      expect(() => service.notifyTransferPaused(), returnsNormally);
      expect(() => service.notifyTransferResumed(), returnsNormally);
      expect(() => service.notifyTransferCancelled(), returnsNormally);
      service.dispose();
    });

    test('sendProgress, sendCompleted, sendFailed execute cleanly', () {
      final service = WebSocketService();
      expect(
        () => service.sendProgress(
          peerId: 'peer_1',
          fileId: 'file_1',
          progress: 50.0,
          bytesTransferred: 1024,
          speedMBps: 20.0,
          chunksCompleted: 1,
          totalChunks: 2,
          timeRemainingSeconds: 5,
        ),
        returnsNormally,
      );
      expect(() => service.sendCompleted('peer_1', 'file_1'), returnsNormally);
      expect(() => service.sendFailed('peer_1', 'file_1', 'test_error'), returnsNormally);
      service.dispose();
    });
  });
}
