import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/file_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_file_selection_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Multi-File Selection & Identity Tests', () {
    test('Selects multiple files in one session and preserves distinct identities', () async {
      final file1 = File('${tempDir.path}/doc1.pdf')..writeAsStringSync('Hello Document 1');
      final file2 = File('${tempDir.path}/video1.mp4')..writeAsBytesSync(List.filled(2048, 42));
      final file3 = File('${tempDir.path}/archive.zip')..writeAsBytesSync(List.filled(1024, 7));

      final selectedFiles = <File>[];
      final fileInfos = <FileInfo>[];

      for (final f in [file1, file2, file3]) {
        if (await f.exists()) {
          selectedFiles.add(f);
          fileInfos.add(await FileInfo.fromFile(f));
        }
      }

      expect(selectedFiles.length, equals(3));
      expect(fileInfos.length, equals(3));

      expect(fileInfos[0].name, equals('doc1.pdf'));
      expect(fileInfos[0].type, equals(FileType.Document));
      expect(fileInfos[0].sizeBytes, equals(16));

      expect(fileInfos[1].name, equals('video1.mp4'));
      expect(fileInfos[1].type, equals(FileType.Video));
      expect(fileInfos[1].sizeBytes, equals(2048));

      expect(fileInfos[2].name, equals('archive.zip'));
      expect(fileInfos[2].type, equals(FileType.Archive));
      expect(fileInfos[2].sizeBytes, equals(1024));
    });

    test('Adding files in a second selection session preserves previously selected files', () async {
      final file1 = File('${tempDir.path}/file1.txt')..writeAsStringSync('First session file');
      final file2 = File('${tempDir.path}/file2.txt')..writeAsStringSync('Second session file');

      final selectedPaths = <String>{};
      final selectedItems = <({File file, FileInfo info})>[];

      // Session 1: pick file1
      if (!selectedPaths.contains(file1.path)) {
        selectedPaths.add(file1.path);
        selectedItems.add((file: file1, info: await FileInfo.fromFile(file1)));
      }

      expect(selectedItems.length, equals(1));
      expect(selectedItems.first.info.name, equals('file1.txt'));

      // Session 2: pick file2 (without removing file1)
      if (!selectedPaths.contains(file2.path)) {
        selectedPaths.add(file2.path);
        selectedItems.add((file: file2, info: await FileInfo.fromFile(file2)));
      }

      expect(selectedItems.length, equals(2));
      expect(selectedItems[0].info.name, equals('file1.txt'));
      expect(selectedItems[1].info.name, equals('file2.txt'));
    });

    test('Duplicate-selection strategy prevents duplicate file entries by canonical path', () async {
      final file = File('${tempDir.path}/unique.png')..writeAsStringSync('Image binary');

      final selectedPaths = <String>{};
      final selectedItems = <File>[];

      // Attempt to add same file twice
      for (int i = 0; i < 3; i++) {
        if (!selectedPaths.contains(file.path)) {
          selectedPaths.add(file.path);
          selectedItems.add(file);
        }
      }

      expect(selectedItems.length, equals(1));
      expect(selectedPaths.length, equals(1));
    });

    test('Files with identical display names but distinct paths are both preserved', () async {
      final subDirA = Directory('${tempDir.path}/folderA')..createSync();
      final subDirB = Directory('${tempDir.path}/folderB')..createSync();

      final fileA = File('${subDirA.path}/report.pdf')..writeAsStringSync('Report from Team A');
      final fileB = File('${subDirB.path}/report.pdf')..writeAsStringSync('Report from Team B is longer');

      final selectedPaths = <String>{};
      final selectedFiles = <File>[];

      for (final f in [fileA, fileB]) {
        if (!selectedPaths.contains(f.path)) {
          selectedPaths.add(f.path);
          selectedFiles.add(f);
        }
      }

      expect(selectedFiles.length, equals(2));
      expect(selectedFiles[0].path, isNot(equals(selectedFiles[1].path)));
      expect(selectedFiles[0].uri.pathSegments.last, equals('report.pdf'));
      expect(selectedFiles[1].uri.pathSegments.last, equals('report.pdf'));
      expect(selectedFiles[0].lengthSync(), isNot(equals(selectedFiles[1].lengthSync())));
    });

    test('Removing one file does not affect remaining files or their order', () async {
      final file1 = File('${tempDir.path}/a.txt')..writeAsStringSync('A');
      final file2 = File('${tempDir.path}/b.txt')..writeAsStringSync('B');
      final file3 = File('${tempDir.path}/c.txt')..writeAsStringSync('C');

      final list = <File>[file1, file2, file3];

      // Remove middle item
      list.removeAt(1);

      expect(list.length, equals(2));
      expect(list[0].path, equals(file1.path));
      expect(list[1].path, equals(file3.path));

      // Clear all
      list.clear();
      expect(list, isEmpty);
    });

    test('Gracefully skips inaccessible or deleted files during selection validation', () async {
      final existingFile = File('${tempDir.path}/exists.txt')..writeAsStringSync('I exist');
      final nonExistentFile = File('${tempDir.path}/ghost.txt');

      final candidates = [existingFile, nonExistentFile];
      final verified = <File>[];

      for (final f in candidates) {
        if (await f.exists()) {
          verified.add(f);
        }
      }

      expect(verified.length, equals(1));
      expect(verified.first.path, equals(existingFile.path));
    });
  });
}
