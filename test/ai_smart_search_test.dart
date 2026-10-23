import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/ai/ai_models.dart';
import 'package:fluxshare/ai/smart_search.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/receiver_progress.dart';
import 'package:fluxshare/models/transfer.dart';

void main() {
  group('Natural Language File Search Tests (Requirement 6)', () {
    late SmartFileSearch searchEngine;
    late List<Transfer> sampleTransfers;

    setUp(() {
      searchEngine = SmartFileSearch();

      final now = DateTime.now();
      sampleTransfers = [
        Transfer(
          id: 't1',
          fileInfo: const FileInfo(
            id: 'f1',
            name: 'vacation_video.mp4',
            sizeBytes: 1500 * 1024 * 1024, // 1.5 GB
            formattedSize: '1.5 GB',
            extension: 'mp4',
            type: FileType.Video,
          ),
          direction: TransferDirection.received,
          status: TransferStatus.completed,
          progressPercent: 100,
          bytesTransferred: 1500 * 1024 * 1024,
          transferSpeedMbPerSec: 32.0,
          remainingSeconds: 0,
          timestamp: now,
          receivers: [
            const ReceiverProgress(peerId: 'p1', deviceName: "Akash's phone", progressPercent: 100)
          ],
          chunkStats: {},
        ),
        Transfer(
          id: 't2',
          fileInfo: const FileInfo(
            id: 'f2',
            name: 'short_clip.mp4',
            sizeBytes: 120 * 1024 * 1024, // 120 MB
            formattedSize: '120 MB',
            extension: 'mp4',
            type: FileType.Video,
          ),
          direction: TransferDirection.received,
          status: TransferStatus.completed,
          progressPercent: 100,
          bytesTransferred: 120 * 1024 * 1024,
          transferSpeedMbPerSec: 25.0,
          remainingSeconds: 0,
          timestamp: now.subtract(const Duration(days: 3)),
          receivers: [
            const ReceiverProgress(peerId: 'p2', deviceName: "Sara's iPhone", progressPercent: 100)
          ],
          chunkStats: {},
        ),
        Transfer(
          id: 't3',
          fileInfo: const FileInfo(
            id: 'f3',
            name: 'quarterly_report.pdf',
            sizeBytes: 15 * 1024 * 1024, // 15 MB
            formattedSize: '15 MB',
            extension: 'pdf',
            type: FileType.Document,
          ),
          direction: TransferDirection.received,
          status: TransferStatus.completed,
          progressPercent: 100,
          bytesTransferred: 15 * 1024 * 1024,
          transferSpeedMbPerSec: 18.0,
          remainingSeconds: 0,
          timestamp: now,
          receivers: [
            const ReceiverProgress(peerId: 'p1', deviceName: "Akash's phone", progressPercent: 100)
          ],
          chunkStats: {},
        ),
      ];
    });

    test('Parses natural language query: "Show videos larger than 1 GB received today"', () {
      final filter = searchEngine.parseQuery('Show videos larger than 1 GB received today');
      expect(filter.category, equals(AIFileCategory.videos));
      expect(filter.minSizeBytes, equals(1024 * 1024 * 1024));
      expect(filter.dateRange, equals('today'));
    });

    test('Filters transfers: "Show videos larger than 1 GB received today"', () {
      final results = searchEngine.searchTransfers(
        query: 'Show videos larger than 1 GB received today',
        transfers: sampleTransfers,
      );

      expect(results.length, equals(1));
      expect(results.first.fileInfo.name, equals('vacation_video.mp4'));
    });

    test('Filters transfers: "Find files larger than 500 MB"', () {
      final results = searchEngine.searchTransfers(
        query: 'Find files larger than 500 MB',
        transfers: sampleTransfers,
      );

      expect(results.length, equals(1));
      expect(results.first.fileInfo.sizeBytes, greaterThan(500 * 1024 * 1024));
    });

    test('Filters transfers: "Show PDFs I received this week"', () {
      final results = searchEngine.searchTransfers(
        query: 'Show PDFs I received this week',
        transfers: sampleTransfers,
      );

      expect(results.length, equals(1));
      expect(results.first.fileInfo.name, equals('quarterly_report.pdf'));
    });

    test('Filters transfers: "Show files received from Akash\'s phone"', () {
      final results = searchEngine.searchTransfers(
        query: "Show files received from Akash's phone",
        transfers: sampleTransfers,
      );

      expect(results.length, equals(2));
      for (final t in results) {
        expect(t.receivers.any((r) => r.deviceName.contains('Akash')), isTrue);
      }
    });

    test('Orders by size when query mentions "largest files"', () {
      final results = searchEngine.searchTransfers(
        query: 'Find the largest files',
        transfers: sampleTransfers,
      );

      expect(results.first.fileInfo.sizeBytes, greaterThan(results.last.fileInfo.sizeBytes));
      expect(results.first.fileInfo.name, equals('vacation_video.mp4'));
    });
  });
}
