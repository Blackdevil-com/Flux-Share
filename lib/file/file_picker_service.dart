import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Real file picker service with robust path resolution, byte fallback,
/// comprehensive diagnostics, and test hook support.
class FilePickerService {
  /// Test hook to simulate picker results in automated unit/widget tests.
  @visibleForTesting
  static Future<List<File>> Function()? customMultiplePickerHandler;

  @visibleForTesting
  static Future<File?> Function()? customSinglePickerHandler;

  static Future<File?> pickSingleFile() async {
    if (customSinglePickerHandler != null) {
      return customSinglePickerHandler!();
    }

    try {
      debugPrint('[FluxShare] Requesting native single-file picker (allowMultiple: false)...');
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) {
        debugPrint('[FluxShare] Single picker cancelled or returned no file.');
        return null;
      }

      final fileItem = result.files.first;
      if (fileItem.path != null && fileItem.path!.isNotEmpty) {
        debugPrint('[FluxShare] Single picker returned: ${fileItem.path}');
        return File(fileItem.path!);
      } else if (fileItem.bytes != null) {
        final tempDir = Directory.systemTemp;
        final tempFile = File('${tempDir.path}/${fileItem.name}');
        await tempFile.writeAsBytes(fileItem.bytes!, flush: true);
        debugPrint('[FluxShare] Single picker cached bytes to temp: ${tempFile.path}');
        return tempFile;
      }
    } catch (e, stack) {
      debugPrint('[FluxShare] FilePickerService.pickSingleFile error: $e\n$stack');
    }
    return null;
  }

  static Future<List<File>> pickMultipleFiles() async {
    if (customMultiplePickerHandler != null) {
      final files = await customMultiplePickerHandler!();
      debugPrint('[FluxShare] Picker returned: ${files.length} files');
      return files;
    }

    try {
      debugPrint('[FluxShare] Requesting native multi-file picker (allowMultiple: true, type: FileType.any)...');
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result == null) {
        debugPrint('[FluxShare] Picker returned: 0 files');
        return [];
      }

      final List<File> resolvedFiles = [];
      for (final f in result.files) {
        if (f.path != null && f.path!.isNotEmpty) {
          final file = File(f.path!);
          resolvedFiles.add(file);
        } else if (f.bytes != null) {
          final tempDir = Directory.systemTemp;
          final safeName = f.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
          final tempFile = File('${tempDir.path}/cached_${DateTime.now().millisecondsSinceEpoch}_$safeName');
          await tempFile.writeAsBytes(f.bytes!, flush: true);
          resolvedFiles.add(tempFile);
          debugPrint('[FluxShare] Resolved non-path file "${f.name}" to cache: ${tempFile.path}');
        } else {
          debugPrint('[FluxShare] Warning: Picked file "${f.name}" has neither path nor bytes available.');
        }
      }

      debugPrint('[FluxShare] Picker returned: ${resolvedFiles.length} files');
      return resolvedFiles;
    } catch (e, stack) {
      debugPrint('[FluxShare] FilePickerService.pickMultipleFiles error: $e\n$stack');
      rethrow;
    }
  }
}
