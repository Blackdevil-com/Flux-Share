import 'dart:io';

/// Security utility for sanitizing filenames and preventing path traversal attacks.
///
/// Ensures incoming file manifests from remote peers cannot escape the designated
/// storage directory or execute arbitrary writes onto the host operating system.
class FilenameSanitizer {
  // Disallowed characters across Windows, Linux, macOS, Android, and iOS
  static final RegExp _invalidChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static const int maxFilenameLength = 255;

  /// Sanitizes a raw filename received from a network peer or manifest.
  ///
  /// 1. Strips directory traversal sequences (`..`, `/`, `\`).
  /// 2. Removes null bytes and control characters.
  /// 3. Replaces illegal Windows/UNIX characters (`:`, `*`, `?`, `"`, `<`, `>`, `|`) with `_`.
  /// 4. Trims leading/trailing whitespace and periods (which can cause issues on Windows).
  /// 5. Enforces a safe fallback name if the result is empty.
  static String sanitize(String? rawName) {
    if (rawName == null || rawName.trim().isEmpty) {
      return 'fluxshare_file_${DateTime.now().millisecondsSinceEpoch}.bin';
    }

    // Extract only the terminal segment if a path was sent
    String name = rawName.replaceAll('\\', '/');
    if (name.contains('/')) {
      name = name.split('/').where((part) => part.isNotEmpty && part != '.' && part != '..').lastOrNull ?? '';
    }

    // Strip explicit traversal dots
    name = name.replaceAll(RegExp(r'^\.+'), '');
    name = name.replaceAll(RegExp(r'\.{2,}'), '.');

    // Replace invalid/control characters with underscore
    name = name.replaceAll(_invalidChars, '_');

    // Trim spaces and trailing dots
    name = name.trim();
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1).trim();
    }

    if (name.isEmpty) {
      return 'fluxshare_file_${DateTime.now().millisecondsSinceEpoch}.bin';
    }

    // Limit length preserving extension if possible
    if (name.length > maxFilenameLength) {
      final extIndex = name.lastIndexOf('.');
      if (extIndex != -1 && (name.length - extIndex) <= 12) {
        final ext = name.substring(extIndex);
        final base = name.substring(0, maxFilenameLength - ext.length);
        name = '$base$ext';
      } else {
        name = name.substring(0, maxFilenameLength);
      }
    }

    return name;
  }

  /// Resolves a non-conflicting unique file inside [directory].
  ///
  /// If `document.pdf` already exists, returns `document (1).pdf`, `document (2).pdf`, etc.
  static Future<File> resolveUniqueFile(Directory directory, String rawFileName) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final sanitized = sanitize(rawFileName);
    final dotIndex = sanitized.lastIndexOf('.');
    final baseName = dotIndex != -1 ? sanitized.substring(0, dotIndex) : sanitized;
    final extension = dotIndex != -1 ? sanitized.substring(dotIndex) : '';

    File candidate = File('${directory.path}/$sanitized');
    int counter = 1;

    while (await candidate.exists()) {
      candidate = File('${directory.path}/$baseName ($counter)$extension');
      counter++;
    }

    return candidate;
  }
}
