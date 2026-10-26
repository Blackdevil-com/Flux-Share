import '../services/storage_diagnostics_service.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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

  const SelectedFilePayload({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.extension,
    required this.type,
    this.identifier,
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
  static Future<SelectedFilePayload?> pickSingleFilePayload() async {
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
      File? resolvedFile;
      if (f.path != null && f.path!.isNotEmpty && File(f.path!).existsSync()) {
        resolvedFile = File(f.path!);
      } else if (f.readStream != null) {
        final tempDir = Directory.systemTemp;
        final safeName = f.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
        final stableKey = identifier != null
            ? sha256.convert(utf8.encode(identifier)).toString().substring(0, 16)
            : '${f.size}';
        resolvedFile = File('${tempDir.path}/fluxshare_tmp_${stableKey}_$safeName');
        if (await resolvedFile.exists() && await resolvedFile.length() == f.size) {
          StorageDiagnosticsService().markTempFileReused(resolvedFile.path);
        } else {
          final sink = resolvedFile.openWrite();
          await f.readStream!.pipe(sink);
          StorageDiagnosticsService().registerTempFile(resolvedFile.path, f.size);
          debugPrint('[FluxShare] Streamed non-path file "${f.name}" to managed temp: ${resolvedFile.path}');
        }
      } else if (f.bytes != null) {
        final tempDir = Directory.systemTemp;
        final safeName = f.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
        final stableKey = identifier != null
            ? sha256.convert(utf8.encode(identifier)).toString().substring(0, 16)
            : '${f.size}';
        resolvedFile = File('${tempDir.path}/fluxshare_tmp_${stableKey}_$safeName');
        if (await resolvedFile.exists() && await resolvedFile.length() == f.size) {
          StorageDiagnosticsService().markTempFileReused(resolvedFile.path);
        } else {
          await resolvedFile.writeAsBytes(f.bytes!, flush: true);
          StorageDiagnosticsService().registerTempFile(resolvedFile.path, f.size);
          debugPrint('[FluxShare] Resolved non-path file "${f.name}" to managed temp: ${resolvedFile.path}');
        }
      }

      if (resolvedFile != null) {
        final ext = f.extension ?? (f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '');
        int size = f.size;
        if (size <= 0 && resolvedFile.existsSync()) {
          try {
            size = resolvedFile.lengthSync();
          } catch (_) {}
        }
        return SelectedFilePayload(
          file: resolvedFile,
          name: f.name,
          sizeBytes: size,
          extension: ext,
          type: fi.FileInfo.detectFileType(ext),
          identifier: identifier,
        );
      }
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
  static Future<List<SelectedFilePayload>> pickMultipleFilePayloads() async {
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
        File? resolvedFile;
        if (f.path != null && f.path!.isNotEmpty && File(f.path!).existsSync()) {
          resolvedFile = File(f.path!);
        } else if (f.readStream != null) {
          final tempDir = Directory.systemTemp;
          final safeName = f.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
          final stableKey = identifier != null
              ? sha256.convert(utf8.encode(identifier)).toString().substring(0, 16)
              : '${f.size}';
          resolvedFile = File('${tempDir.path}/fluxshare_tmp_${stableKey}_$safeName');
          if (await resolvedFile.exists() && await resolvedFile.length() == f.size) {
            StorageDiagnosticsService().markTempFileReused(resolvedFile.path);
          } else {
            final sink = resolvedFile.openWrite();
            await f.readStream!.pipe(sink);
            StorageDiagnosticsService().registerTempFile(resolvedFile.path, f.size);
            debugPrint('[FluxShare] Streamed non-path file "${f.name}" to managed temp: ${resolvedFile.path}');
          }
        } else if (f.bytes != null) {
          final tempDir = Directory.systemTemp;
          final safeName = f.name.replaceAll(RegExp(r'[^\w\.-]'), '_');
          final stableKey = identifier != null
              ? sha256.convert(utf8.encode(identifier)).toString().substring(0, 16)
              : '${f.size}';
          resolvedFile = File('${tempDir.path}/fluxshare_tmp_${stableKey}_$safeName');
          if (await resolvedFile.exists() && await resolvedFile.length() == f.size) {
            StorageDiagnosticsService().markTempFileReused(resolvedFile.path);
          } else {
            await resolvedFile.writeAsBytes(f.bytes!, flush: true);
            StorageDiagnosticsService().registerTempFile(resolvedFile.path, f.size);
            debugPrint('[FluxShare] Resolved non-path file "${f.name}" to managed temp: ${resolvedFile.path}');
          }
        }

        if (resolvedFile != null) {
          final ext = f.extension ?? (f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '');
          int size = f.size;
          if (size <= 0 && resolvedFile.existsSync()) {
            try {
              size = resolvedFile.lengthSync();
            } catch (_) {}
          }
          payloads.add(SelectedFilePayload(
            file: resolvedFile,
            name: f.name,
            sizeBytes: size,
            extension: ext,
            type: fi.FileInfo.detectFileType(ext),
            identifier: identifier,
          ));
        } else {
          debugPrint('[FluxShare] Warning: Picked file "${f.name}" has neither path nor bytes available.');
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
