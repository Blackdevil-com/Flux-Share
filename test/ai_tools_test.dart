import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/ai/ai_service.dart';
import 'package:fluxshare/ai/ai_tools.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/transfer.dart';
import 'package:fluxshare/repositories/transfer_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AI Assistant Structured Tools Tests (Requirement 5)', () {
    late TransferRepository transferRepo;
    late AIService aiService;

    setUp(() async {
      transferRepo = TransferRepository();
      await transferRepo.init();
      aiService = AIService();
      await aiService.init();

      // Seed a test transfer record
      final testTransfer = Transfer(
        id: 'test_tx_ai_tool',
        fileInfo: const FileInfo(
          id: 'test_file_id',
          name: 'Ubuntu.iso',
          sizeBytes: 4 * 1024 * 1024 * 1024,
          formattedSize: '4.0 GB',
          extension: 'iso',
          type: FileType.Archive,
        ),
        direction: TransferDirection.received,
        status: TransferStatus.completed,
        progressPercent: 100,
        bytesTransferred: 4 * 1024 * 1024 * 1024,
        transferSpeedMbPerSec: 28.0,
        remainingSeconds: 0,
        timestamp: DateTime.now(),
        receivers: [],
        chunkStats: {'chunks': 420, 'retries': 3},
      );

      transferRepo.updateTransfer(testTransfer);
    });

    test('get_transfer_history returns actual records', () async {
      final history = await AITools.getTransferHistory();
      expect(history, isNotEmpty);
      expect(history.any((t) => t['fileName'] == 'Ubuntu.iso'), isTrue);
    });

    test('get_file_metadata retrieves matching metadata by name', () async {
      final meta = await AITools.getFileMetadata('Ubuntu');
      expect(meta, isNotNull);
      expect(meta!['fileName'], equals('Ubuntu.iso'));
      expect(meta['sizeBytes'], equals(4 * 1024 * 1024 * 1024));
    });

    test('get_network_statistics returns valid local peer and ports', () async {
      final stats = await AITools.getNetworkStatistics();
      expect(stats['localPeerId'], isNotEmpty);
      expect(stats['serverPort'], equals(8080));
    });

    test('get_transfer_statistics aggregates throughput correctly without inventing data', () async {
      final stats = await AITools.getTransferStatistics();
      expect(stats['totalTransfers'], greaterThan(0));
      expect(stats['completedTransfers'], greaterThan(0));
      expect(stats['averageThroughputMbPerSec'], greaterThan(0.0));
    });

    test('AI Assistant answers "Why is my transfer slow?" using structured tools', () async {
      final response = await aiService.askAssistant('Why is my transfer slow?');
      expect(response.role, equals('assistant'));
      expect(response.toolBadges, contains('get_transfer_statistics()'));
      expect(response.content, contains('Average Speed'));
    });

    test('AI Assistant answers "How many files did I receive today?" accurately', () async {
      final response = await aiService.askAssistant('How many files did I receive today?');
      expect(response.role, equals('assistant'));
      expect(response.toolBadges, contains('get_transfer_history()'));
      expect(response.content, contains('Received:'));
    });
  });
}
