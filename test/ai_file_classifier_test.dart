import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/ai/ai_models.dart';
import 'package:fluxshare/ai/file_classifier.dart';

void main() {
  group('AI File Classifier Tests (Requirement 1)', () {
    late AIFileClassifier classifier;

    setUp(() {
      classifier = AIFileClassifier();
    });

    test('Classifies photographic images to Photos folder with high confidence', () async {
      final res = await classifier.classifyFile(fileName: 'vacation_2026.jpg');
      expect(res.category, equals(AIFileCategory.images));
      expect(res.confidence, greaterThanOrEqualTo(0.95));
      expect(res.suggestedFolder, equals('Photos'));
      expect(res.mimeType, equals('image/jpeg'));
    });

    test('Classifies video containers correctly to Videos folder', () async {
      final res = await classifier.classifyFile(fileName: 'tutorial_video.mp4', sizeBytes: 150000000);
      expect(res.category, equals(AIFileCategory.videos));
      expect(res.suggestedFolder, equals('Videos'));
      expect(res.mimeType, equals('video/mp4'));
    });

    test('Classifies PDFs into PDFs category and folder', () async {
      final res = await classifier.classifyFile(fileName: 'annual_report.pdf');
      expect(res.category, equals(AIFileCategory.pdfs));
      expect(res.suggestedFolder, equals('PDFs'));
      expect(res.mimeType, equals('application/pdf'));
    });

    test('Classifies presentations (PPTX) correctly', () async {
      final res = await classifier.classifyFile(fileName: 'pitch_deck.pptx');
      expect(res.category, equals(AIFileCategory.presentations));
      expect(res.suggestedFolder, equals('Presentations'));
    });

    test('Classifies spreadsheets (CSV and XLSX)', () async {
      final csvRes = await classifier.classifyFile(fileName: 'financial_data.csv');
      expect(csvRes.category, equals(AIFileCategory.spreadsheets));
      expect(csvRes.suggestedFolder, equals('Spreadsheets'));

      final xlsxRes = await classifier.classifyFile(fileName: 'budget.xlsx');
      expect(xlsxRes.category, equals(AIFileCategory.spreadsheets));
      expect(xlsxRes.suggestedFolder, equals('Spreadsheets'));
    });

    test('Classifies archives (ZIP, TAR, ISO)', () async {
      final res = await classifier.classifyFile(fileName: 'Ubuntu.iso');
      expect(res.category, equals(AIFileCategory.archives));
      expect(res.suggestedFolder, equals('Archives'));
    });

    test('Classifies source code (Dart, Kotlin, Python)', () async {
      final dartRes = await classifier.classifyFile(fileName: 'main.dart');
      expect(dartRes.category, equals(AIFileCategory.code));
      expect(dartRes.suggestedFolder, equals('Development'));

      final ktRes = await classifier.classifyFile(fileName: 'HomeScreen.kt');
      expect(ktRes.category, equals(AIFileCategory.code));
      expect(ktRes.suggestedFolder, equals('Development'));
    });

    test('Classifies audio songs to Music folder', () async {
      final res = await classifier.classifyFile(fileName: 'acoustic_track.mp3');
      expect(res.category, equals(AIFileCategory.audio));
      expect(res.suggestedFolder, equals('Music'));
    });

    test('Classifies unrecognized binary extensions to Downloads as Other', () async {
      final res = await classifier.classifyFile(fileName: 'firmware.bin');
      expect(res.category, equals(AIFileCategory.other));
      expect(res.suggestedFolder, equals('Downloads'));
    });
  });
}
