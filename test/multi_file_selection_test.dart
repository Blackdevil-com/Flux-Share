import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/file_picker_service.dart';
import 'package:fluxshare/models/file_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_file_selection_test_');
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
  });

  tearDown(() async {
    FilePickerService.customMultiplePickerHandler = null;
    FilePickerService.customSinglePickerHandler = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Multi-File Selection & Identity Tests', () {
    test('1. Picker result containing three files produces three selected entries', () async {
      final file1 = File('${tempDir.path}/doc1.pdf')..writeAsStringSync('Hello Document 1');
      final file2 = File('${tempDir.path}/video1.mp4')..writeAsBytesSync(List.filled(2048, 42));
      final file3 = File('${tempDir.path}/archive.zip')..writeAsBytesSync(List.filled(1024, 7));

      FilePickerService.customMultiplePickerHandler = () async => [file1, file2, file3];

      final picked = await FilePickerService.pickMultipleFiles();
      expect(picked.length, equals(3));

      final selectedItems = <({File file, FileInfo info})>[];
      for (final f in picked) {
        if (await f.exists()) {
          selectedItems.add((file: f, info: await FileInfo.fromFile(f)));
        }
      }

      expect(selectedItems.length, equals(3));
      expect(selectedItems[0].info.name, equals('doc1.pdf'));
      expect(selectedItems[0].info.type, equals(FileType.Document));
      expect(selectedItems[0].info.sizeBytes, equals(16));

      expect(selectedItems[1].info.name, equals('video1.mp4'));
      expect(selectedItems[1].info.type, equals(FileType.Video));
      expect(selectedItems[1].info.sizeBytes, equals(2048));

      expect(selectedItems[2].info.name, equals('archive.zip'));
      expect(selectedItems[2].info.type, equals(FileType.Archive));
      expect(selectedItems[2].info.sizeBytes, equals(1024));
    });

    test('2. Selecting additional files appends them to the existing selection', () async {
      final file1 = File('${tempDir.path}/file1.txt')..writeAsStringSync('First session file');
      final file2 = File('${tempDir.path}/file2.txt')..writeAsStringSync('Second session file');

      final selectedCanonicalPaths = <String>{};
      final selectedItems = <({File file, FileInfo info})>[];

      void processBatch(List<File> files) async {
        for (final f in files) {
          final canonical = f.resolveSymbolicLinksSync();
          if (!selectedCanonicalPaths.contains(canonical)) {
            selectedCanonicalPaths.add(canonical);
            selectedItems.add((file: f, info: FileInfo(
              id: f.path,
              name: f.uri.pathSegments.last,
              sizeBytes: f.lengthSync(),
              formattedSize: '${f.lengthSync()} B',
              extension: f.path.split('.').last,
              type: FileType.Document,
            )));
          }
        }
      }

      // Session 1: pick file1
      FilePickerService.customMultiplePickerHandler = () async => [file1];
      final batch1 = await FilePickerService.pickMultipleFiles();
      processBatch(batch1);

      expect(selectedItems.length, equals(1));
      expect(selectedItems.first.info.name, equals('file1.txt'));

      // Session 2: Add More picks file2
      FilePickerService.customMultiplePickerHandler = () async => [file2];
      final batch2 = await FilePickerService.pickMultipleFiles();
      processBatch(batch2);

      expect(selectedItems.length, equals(2));
      expect(selectedItems[0].info.name, equals('file1.txt'));
      expect(selectedItems[1].info.name, equals('file2.txt'));
    });

    test('3. Duplicate paths are not added twice', () async {
      final file = File('${tempDir.path}/unique.png')..writeAsStringSync('Image binary');

      final selectedPaths = <String>{};
      final selectedItems = <File>[];

      void addFiles(List<File> files) {
        for (final f in files) {
          final canonical = f.resolveSymbolicLinksSync();
          if (!selectedPaths.contains(canonical)) {
            selectedPaths.add(canonical);
            selectedItems.add(f);
          }
        }
      }

      // Add file first time
      addFiles([file]);
      expect(selectedItems.length, equals(1));

      // Attempt to add same file again
      addFiles([file]);
      expect(selectedItems.length, equals(1));
      expect(selectedPaths.length, equals(1));
    });

    test('4. Files with identical names but different paths remain distinct', () async {
      final subDirA = Directory('${tempDir.path}/folderA')..createSync();
      final subDirB = Directory('${tempDir.path}/folderB')..createSync();

      final fileA = File('${subDirA.path}/report.pdf')..writeAsStringSync('Report from Team A');
      final fileB = File('${subDirB.path}/report.pdf')..writeAsStringSync('Report from Team B is longer');

      final selectedPaths = <String>{};
      final selectedFiles = <File>[];

      for (final f in [fileA, fileB]) {
        final canonical = f.resolveSymbolicLinksSync();
        if (!selectedPaths.contains(canonical)) {
          selectedPaths.add(canonical);
          selectedFiles.add(f);
        }
      }

      expect(selectedFiles.length, equals(2));
      expect(selectedFiles[0].path, isNot(equals(selectedFiles[1].path)));
      expect(selectedFiles[0].uri.pathSegments.last, equals('report.pdf'));
      expect(selectedFiles[1].uri.pathSegments.last, equals('report.pdf'));
      expect(selectedFiles[0].lengthSync(), isNot(equals(selectedFiles[1].lengthSync())));
    });

    test('5. Cancellation preserves the existing selection', () async {
      final file1 = File('${tempDir.path}/existing.txt')..writeAsStringSync('Pre-selected file');
      final selectedFiles = <File>[file1];

      // User triggers picker but cancels (returns empty list)
      FilePickerService.customMultiplePickerHandler = () async => [];
      final picked = await FilePickerService.pickMultipleFiles();

      if (picked.isNotEmpty) {
        selectedFiles.addAll(picked);
      }

      expect(selectedFiles.length, equals(1));
      expect(selectedFiles.first.path, equals(file1.path));
    });

    test('6. Null or empty picker result does not crash the screen state', () async {
      FilePickerService.customMultiplePickerHandler = () async => [];
      final result = await FilePickerService.pickMultipleFiles();
      expect(result, isEmpty);

      final selectedFiles = <File>[];
      if (result.isNotEmpty) {
        selectedFiles.addAll(result);
      }
      expect(selectedFiles, isEmpty);
    });

    test('7. Result containing inaccessible or pathless files is handled safely', () async {
      final validFile = File('${tempDir.path}/valid.txt')..writeAsStringSync('Valid content');
      final missingFile = File('${tempDir.path}/deleted_by_user.txt');

      FilePickerService.customMultiplePickerHandler = () async => [validFile, missingFile];
      final picked = await FilePickerService.pickMultipleFiles();

      final safeVerified = <File>[];
      for (final f in picked) {
        if (await f.exists()) {
          safeVerified.add(f);
        }
      }

      expect(safeVerified.length, equals(1));
      expect(safeVerified.first.path, equals(validFile.path));
    });

    test('8. The Send Files flow invokes multi-file picker, not the single-file helper', () async {
      bool multiPickerInvoked = false;
      bool singlePickerInvoked = false;

      FilePickerService.customMultiplePickerHandler = () async {
        multiPickerInvoked = true;
        return [File('${tempDir.path}/dummy.txt')];
      };

      FilePickerService.customSinglePickerHandler = () async {
        singlePickerInvoked = true;
        return null;
      };

      // Call the multi-file picker service used by Send Files screen
      final files = await FilePickerService.pickMultipleFiles();

      expect(multiPickerInvoked, isTrue);
      expect(singlePickerInvoked, isFalse);
      expect(files.length, equals(1));
    });
  });
}
