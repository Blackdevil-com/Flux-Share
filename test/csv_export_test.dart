import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/metrics/metrics_collector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CSV Export Tests (Phase D3)', () {
    late MetricsCollector collector;

    setUp(() {
      collector = MetricsCollector();
    });

    test('Exports transfer metrics with proper RFC 4180 escaping and headers', () async {
      collector.startTransfer(
        transferId: 'xfer-csv-1',
        fileId: 'file-101',
        fileName: 'presentation, "final draft".pdf', // Contains comma and quotes
        fileSize: 10485760,
        chunkCount: 10,
        chunkSize: 1048576,
        coordinatorPeerId: 'coordinator-host',
        receiverCount: 3,
        schedulerMode: 'ucb1-adaptive',
        networkMode: 'hotspot',
      );

      collector.recordTimeToFirstByte(0, 45);
      collector.recordTimeToFirstPreviewReady(120);
      collector.recordChunkDelivered(
        sourcePeerId: 'coordinator-host',
        receiverPeerId: 'rx-1',
        bytes: 1048576,
      );
      collector.recordChunkDelivered(
        sourcePeerId: 'rx-2-forwarder',
        receiverPeerId: 'rx-1',
        bytes: 1048576,
      );
      collector.recordRetransmission();

      final metrics = await collector.finalizeTransfer();
      expect(metrics, isNotNull);

      final csv = collector.exportHistoryToCsv();
      final lines = csv.trim().split('\n');

      expect(lines.isNotEmpty, isTrue);

      // Verify Header line
      expect(
        lines[0].trim(),
        equals(
          'TransferId,FileId,FileName,FileSize,ChunkCount,ChunkSize,'
          'ReceiverCount,NetworkMode,SchedulerMode,TotalDurationMs,'
          'AggregateThroughputMbps,SenderUploadBytes,CooperativeForwardBytes,'
          'CooperativeRatio,Retransmissions,AvgTtfbMs,TimeToPreviewReadyMs,StartTime,EndTime',
        ),
      );

      // Find the line for our transfer
      final recordLine = lines.firstWhere((line) => line.contains('xfer-csv-1'));

      // Validate RFC 4180 double-quoting around quotes and commas
      expect(recordLine, contains('"presentation, ""final draft"".pdf"'));
      expect(recordLine, contains('file-101'));
      expect(recordLine, contains('hotspot'));
      expect(recordLine, contains('ucb1-adaptive'));
      expect(recordLine, contains('1048576')); // Sender upload bytes
      expect(recordLine, contains('45.0')); // Avg TTFB
      expect(recordLine, contains('120')); // Preview ready time
    });

    test('Generates valid CSV file on disk', () async {
      final tempDir = await Directory.systemTemp.createTemp('fluxshare_csv_test_');
      final targetFile = File('${tempDir.path}/export_metrics.csv');

      final csvContent = collector.exportHistoryToCsv();
      await targetFile.writeAsString(csvContent, flush: true);

      expect(targetFile.existsSync(), isTrue);
      final readBack = await targetFile.readAsString();
      expect(readBack, contains('TransferId,FileId,FileName'));

      await tempDir.delete(recursive: true);
    });
  });
}
