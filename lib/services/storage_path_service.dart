import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_diagnostics_service.dart';

/// Centralized service for determining user-accessible destination directories
/// and managing system media indexing across platforms.
class StoragePathService {
  static const MethodChannel _channel =
      MethodChannel('com.example.fluxshare/background_service');

  @visibleForTesting
  static Directory? customSaveDirectory;

  @visibleForTesting
  static Future<void> Function(String path)? customScanFileHandler;

  /// Returns the user-accessible directory where received files should be stored.
  /// On Android, prefers the public standard 'Download/FluxShare' directory
  /// (/storage/emulated/0/Download/FluxShare).
  /// Falls back to external files or documents if standard download path is inaccessible.
  static Future<Directory> getReceivedFilesDirectory() async {
    if (customSaveDirectory != null) {
      if (!await customSaveDirectory!.exists()) {
        await customSaveDirectory!.create(recursive: true);
      }
      return customSaveDirectory!;
    }

    if (Platform.isAndroid) {
      // 1. Preferred user-visible public storage: /storage/emulated/0/Download/FluxShare
      try {
        final publicDownloadDir = Directory('/storage/emulated/0/Download');
        if (await publicDownloadDir.exists()) {
          final fluxDir = Directory('/storage/emulated/0/Download/FluxShare');
          if (!await fluxDir.exists()) {
            await fluxDir.create(recursive: true);
          }
          return fluxDir;
        }
      } catch (e) {
        debugPrint('[StoragePathService] Public Download folder unavailable: $e');
      }

      // 2. Fallback to external storage directory
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final fluxDir = Directory('${extDir.path}/FluxShare');
          if (!await fluxDir.exists()) {
            await fluxDir.create(recursive: true);
          }
          return fluxDir;
        }
      } catch (e) {
        debugPrint('[StoragePathService] External storage unavailable: $e');
      }
    }

    // 3. Desktop / iOS / standard downloads directory
    try {
      final dlDir = await getDownloadsDirectory();
      if (dlDir != null) {
        final fluxDir = Directory('${dlDir.path}/FluxShare');
        if (!await fluxDir.exists()) {
          await fluxDir.create(recursive: true);
        }
        return fluxDir;
      }
    } catch (e) {
      debugPrint('[StoragePathService] getDownloadsDirectory error: $e');
    }

    // 4. Final fallback to documents directory
    final docDir = await getApplicationDocumentsDirectory();
    final fluxDir = Directory('${docDir.path}/FluxShare');
    if (!await fluxDir.exists()) {
      await fluxDir.create(recursive: true);
    }
    return fluxDir;
  }

  /// Triggers Android's MediaScannerConnection to index the saved file
  /// so that it appears immediately in the Files app, Gallery, and Downloads app.
  static Future<void> scanFile(String filePath) async {
    if (customScanFileHandler != null) {
      await customScanFileHandler!(filePath);
      return;
    }

    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('scanMediaFile', {'path': filePath});
        debugPrint('[StoragePathService] MediaScanner scan requested for: $filePath');
      } catch (e) {
        debugPrint('[StoragePathService] MediaScanner scan error: $e');
      }
    }
  }

  /// Queries the available bytes on the filesystem backing the received files directory.
  static Future<int?> getAvailableStorageBytes() async {
    try {
      final dir = await getReceivedFilesDirectory();
      return await StorageDiagnosticsService().getAvailableStorageBytes(dir.path);
    } catch (e) {
      debugPrint('[StoragePathService] getAvailableStorageBytes error: $e');
      return null;
    }
  }
}
