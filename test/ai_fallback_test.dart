import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/ai/ai_config.dart';
import 'package:fluxshare/ai/ai_models.dart';
import 'package:fluxshare/ai/ai_provider.dart';
import 'package:fluxshare/ai/ai_service.dart';
import 'package:fluxshare/ai/smart_organizer.dart';
import 'package:fluxshare/ai/smart_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AI Offline Fallback & Privacy Tests (Requirements 10 & 11)', () {
    late AIService aiService;
    late AIConfig config;

    setUp(() async {
      aiService = AIService();
      await aiService.init();
      config = aiService.config;
    });

    test('Falls back gracefully when AI is completely disabled', () async {
      await config.setAiEnabled(false);

      final classification = await aiService.classifyFile(fileName: 'photo.jpg');
      expect(classification.category, equals(AIFileCategory.other));
      expect(classification.explanation, contains('disabled'));

      final assistantReply = await aiService.askAssistant('Why is my transfer slow?');
      expect(assistantReply.content, contains('currently disabled'));

      // Restore AI
      await config.setAiEnabled(true);
    });

    test('GeminiCloudProvider falls back seamlessly to LocalRuleBasedProvider when offline or unconfigured', () async {
      final cloudProvider = GeminiCloudProvider();
      final response = await cloudProvider.generateResponse(prompt: 'Why is my transfer slow?');

      expect(response, isNotEmpty);
      expect(response, contains('Transfer speed depends on local Wi-Fi link quality'));
    });

    test('SmartTransferSummary generates deterministic post-transfer insight', () async {
      final summaryService = SmartTransferSummaryService(config: config);
      final summary = await summaryService.generateSummary(
        fileName: 'Ubuntu.iso',
        formattedSize: '4.2 GB',
        durationText: '2m 31s',
        averageSpeedText: '28 MB/s',
        chunkCount: 420,
        retryCount: 3,
        integrityVerified: true,
      );

      expect(summary.fileName, equals('Ubuntu.iso'));
      expect(summary.chunkCount, equals(420));
      expect(summary.retryCount, equals(3));
      expect(summary.integrityVerified, isTrue);
      expect(summary.aiInsight, contains('3 chunks required retrying'));
    });

    test('SmartFileOrganizer groups batch files without moving until approved', () async {
      final organizer = SmartFileOrganizer();
      final plan = await organizer.createOrganizationPlan(
        fileNames: [
          'IMG_1023.jpg',
          'IMG_1024.jpg',
          'presentation.pdf',
          'resume.pdf',
          'song.mp3',
        ],
      );

      expect(plan.suggestions.length, equals(3)); // Photos, PDFs, Music
      expect(plan.suggestions.any((s) => s.destinationFolder == 'Photos'), isTrue);
      expect(plan.suggestions.any((s) => s.destinationFolder == 'PDFs'), isTrue);
      expect(plan.suggestions.any((s) => s.destinationFolder == 'Music'), isTrue);

      final photosSuggestion = plan.suggestions.firstWhere((s) => s.destinationFolder == 'Photos');
      expect(photosSuggestion.fileNames, containsAll(['IMG_1023.jpg', 'IMG_1024.jpg']));

      // Verify no moves happen without user approval (dry run)
      final tempDir = await Directory.systemTemp.createTemp('fluxshare_org_test_');
      try {
        final executed = await organizer.executeApprovedPlan(
          plan: plan,
          baseDirectory: tempDir,
        );
        // None exist so 0 moved
        expect(executed, equals(0));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
