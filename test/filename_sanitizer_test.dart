import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/filename_sanitizer.dart';

void main() {
  group('FilenameSanitizer Unit Tests', () {
    test('Strips simple path traversal sequences', () {
      final sanitized = FilenameSanitizer.sanitize('../../secret.txt');
      expect(sanitized, equals('secret.txt'));
      expect(sanitized.contains('/'), isFalse);
      expect(sanitized.contains('\\'), isFalse);
      expect(sanitized.contains('..'), isFalse);
    });

    test('Strips nested and mixed traversal sequences', () {
      final sanitized = FilenameSanitizer.sanitize('..\\..\\..\\Windows\\System32\\cmd.exe');
      expect(sanitized, equals('cmd.exe'));
    });

    test('Strips absolute UNIX paths', () {
      final sanitized = FilenameSanitizer.sanitize('/etc/passwd');
      expect(sanitized, equals('passwd'));
    });

    test('Replaces illegal characters with underscores', () {
      final sanitized = FilenameSanitizer.sanitize('report:2026*final?.pdf');
      expect(sanitized, equals('report_2026_final_.pdf'));
    });

    test('Trims trailing dots and spaces', () {
      final sanitized = FilenameSanitizer.sanitize('  my_notes...  ');
      expect(sanitized, equals('my_notes'));
    });

    test('Falls back to safe name when input is empty or dots only', () {
      final sanitized = FilenameSanitizer.sanitize('....');
      expect(sanitized.startsWith('fluxshare_file_'), isTrue);
      expect(sanitized.endsWith('.bin'), isTrue);
    });

    test('Resolves unique non-conflicting filenames on collision', () async {
      final tempDir = await Directory.systemTemp.createTemp('fluxshare_test_');
      try {
        final file1 = await FilenameSanitizer.resolveUniqueFile(tempDir, 'test_file.txt');
        expect(file1.path.endsWith('test_file.txt'), isTrue);
        await file1.writeAsString('first');

        final file2 = await FilenameSanitizer.resolveUniqueFile(tempDir, 'test_file.txt');
        expect(file2.path.endsWith('test_file (1).txt'), isTrue);
        await file2.writeAsString('second');

        final file3 = await FilenameSanitizer.resolveUniqueFile(tempDir, 'test_file.txt');
        expect(file3.path.endsWith('test_file (2).txt'), isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
