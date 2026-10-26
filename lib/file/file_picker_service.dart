import '../services/managed_temporary_file_service.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../models/file_info.dart' as fi;

/// Immutable payload containing metadata immediately extracted upon file selection.
class SelectedFilePayload {
  final File file;
  final String name;
  final int sizeBytes;
  final String extension;
  final fi.FileType type;
  final String? identifier;
  final bool isManaged;
  final String? sessionId;

  const SelectedFilePayload({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.extension,
    required this.type,
    this.identifier,
    this.isManaged = false,
    this.sessionId,
  });

  fi.FileInfo toFileInfo() {
    return fi.FileInfo.fromMetadata(
      path: file.path,
      name: name,
      sizeBytes: sizeBytes,
      extension: extension,
      type: type,
    );
  }
}

/// Real file picker service with robust path resolution, byte fallback,
/// comprehensive diagnostics, and test hook support.
class FilePickerService {
  /// Test hook to simulate picker results in automated unit/widget tests.
  @visibleForTesting
  static Future<List<File>> Function()? customMultiplePickerHandler;

  @visibleForTesting
  static Future<List<SelectedFilePayload>> Function()? customPayloadPickerHandler;

  @visibleForTesting
  static Future<File?> Function()? customSinglePickerHandler;

  @visibleForTesting
  static Future<SelectedFilePayload?> Function()? customSinglePayloadPickerHandler;

  /// Selects a single replacement file and immediately returns a lightweight metadata payload
  /// without requiring expensive synchronous disk I/O.
  static Future<SelectedFilePayload?> pickSingleFilePayload({String? sessionId}) async {
    final effectiveSessionId = sessionId ?? 'single_picker_${DateTime.now().millisecondsSinceEpoch}';

    if (customSinglePayloadPickerHandler != null) {
      final payload = await customSinglePayloadPickerHandler!();
      debugPrint('[FluxShare] Single picker returned payload: ${payload?.name}');
      return payload;
    }

    if (customSinglePickerHandler != null) {
      final f = await customSinglePickerHandler!();
      if (f == null) return null;
      final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : 'file';
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      int size = 0;
      try {
        if (f.existsSync()) size = f.lengthSync();
      } catch (_) {}
      return SelectedFilePayload(
        file: f,
        name: name,
        sizeBytes: size,
        extension: ext,
        type: fi.FileInfo.detectFileType(ext),
        isManaged: false,
        sessionId: effectiveSessionId,
      );
    }

    try {
      debugPrint('[FluxShare] Requesting native single-file picker (allowMultiple: false, type: FileType.any)...');
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
        withData: false,
        withReadStream: true,
      );
      if (result == null || result.files.isEmpty) {
        debugPrint('[FluxShare] Single picker cancelled or returned no file.');
        return null;
      }

      final f = result.files.first;
      final String? identifier = f.identifier;
      final ext = f.extension ?? (f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '');

      final managedRef = await ManagedTemporaryFileService.instance.getOrCreateManagedCopy(
        sessionId: effectiveSessionId,
        fileId: identifier ?? f.name,
        name: f.name,
        sizeBytes: f.size,
        path: f.path,
        readStream: f.readStream,
        bytes: f.bytes,
        identifier: identifier,
      );

      return SelectedFilePayload(
        file: managedRef.file,
        name: f.name,
        sizeBytes: managedRef.sizeBytes,
        extension: ext,
        type: fi.FileInfo.detectFileType(ext),
        identifier: identifier,
        isManaged: managedRef.isManaged,
        sessionId: effectiveSessionId,
      );
    } catch (e, stack) {
      debugPrint('[FluxShare] FilePickerService.pickSingleFilePayload error: $e\n$stack');
    }
    return null;
  }

  static Future<File?> pickSingleFile() async {
    final payload = await pickSingleFilePayload();
    return payload?.file;
  }

  /// Selects multiple files and immediately returns lightweight metadata payloads
  /// without requiring expensive synchronous disk I/O.
  static Future<List<SelectedFilePayload>> pickMultipleFilePayloads({String? sessionId}) async {
    final effectiveSessionId = sessionId ?? 'multi_picker_${DateTime.now().millisecondsSinceEpoch}';

    if (customPayloadPickerHandler != null) {
      final payloads = await customPayloadPickerHandler!();
      debugPrint('[FluxShare] Picker returned: ${payloads.length} payloads');
      return payloads;
    }

    if (customMultiplePickerHandler != null) {
      final files = await customMultiplePickerHandler!();
      debugPrint('[FluxShare] Picker returned: ${files.length} files (fallback)');
      return files.map((f) {
        final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : 'file';
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
        int size = 0;
        try {
          if (f.existsSync()) size = f.lengthSync();
        } catch (_) {}
        return SelectedFilePayload(
          file: f,
          name: name,
          sizeBytes: size,
          extension: ext,
          type: fi.FileInfo.detectFileType(ext),
          isManaged: false,
          sessionId: effectiveSessionId,
        );
      }).toList();
    }

    try {
      debugPrint('[FluxShare] Requesting native multi-file picker (allowMultiple: true, type: FileType.any)...');
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
        withReadStream: true,
      );

      if (result == null) {
        debugPrint('[FluxShare] Picker returned: 0 files');
        return [];
      }

      final List<SelectedFilePayload> payloads = [];
      for (final f in result.files) {
        final String? identifier = f.identifier;
        final ext = f.extension ?? (f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '');

        try {
          final managedRef = await ManagedTemporaryFileService.instance.getOrCreateManagedCopy(
            sessionId: effectiveSessionId,
            fileId: identifier ?? f.name,
            name: f.name,
            sizeBytes: f.size,
            path: f.path,
            readStream: f.readStream,
            bytes: f.bytes,
            identifier: identifier,
          );

          payloads.add(SelectedFilePayload(
            file: managedRef.file,
            name: f.name,
            sizeBytes: managedRef.sizeBytes,
            extension: ext,
            type: fi.FileInfo.detectFileType(ext),
            identifier: identifier,
            isManaged: managedRef.isManaged,
            sessionId: effectiveSessionId,
          ));
        } catch (fileErr) {
          debugPrint('[FluxShare] Warning: Could not resolve picked file "${f.name}": $fileErr');
        }
      }

      debugPrint('[FluxShare] Picker returned: ${payloads.length} files');
      return payloads;
    } catch (e, stack) {
      debugPrint('[FluxShare] FilePickerService.pickMultipleFilePayloads error: $e\n$stack');
      rethrow;
    }
  }

  /// Retained for backward compatibility. Returns raw File objects.
  static Future<List<File>> pickMultipleFiles() async {
    final payloads = await pickMultipleFilePayloads();
    return payloads.map((p) => p.file).toList();
  }
}
