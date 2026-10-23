import 'dart:io';
import 'ai_models.dart';
import 'file_classifier.dart';

/// Suggests and securely executes structured file organization for received transfers.
/// Critical Safety Rule: NEVER moves or deletes files without explicit user approval.
class SmartFileOrganizer {
  final AIFileClassifier _classifier;

  SmartFileOrganizer({AIFileClassifier? classifier})
      : _classifier = classifier ?? AIFileClassifier();

  /// Analyzes a batch of files and constructs an organization proposal.
  Future<AIBatchOrganizationPlan> createOrganizationPlan({
    required List<String> fileNames,
    Map<String, int>? fileSizes,
  }) async {
    final Map<String, List<String>> folderToFileMap = {};
    final Map<String, AIFileCategory> folderCategoryMap = {};

    for (final name in fileNames) {
      final size = fileSizes?[name] ?? 0;
      final classification = await _classifier.classifyFile(
        fileName: name,
        sizeBytes: size,
      );

      final folder = classification.suggestedFolder;
      folderToFileMap.putIfAbsent(folder, () => []).add(name);
      folderCategoryMap[folder] = classification.category;
    }

    final suggestions = folderToFileMap.entries.map((entry) {
      return AIOrganizationSuggestion(
        destinationFolder: entry.key,
        fileNames: entry.value,
        category: folderCategoryMap[entry.key] ?? AIFileCategory.other,
        isAccepted: true,
      );
    }).toList();

    final folderCount = suggestions.length;
    final fileCount = fileNames.length;
    final summary =
        'Organize $fileCount ${fileCount == 1 ? 'file' : 'files'} into '
        '$folderCount ${folderCount == 1 ? 'folder' : 'folders'}: '
        '${suggestions.map((s) => '${s.destinationFolder}/ (${s.fileNames.length})').join(', ')}';

    return AIBatchOrganizationPlan(
      suggestions: suggestions,
      summary: summary,
    );
  }

  /// Executes ONLY user-approved moves in the base storage directory.
  Future<int> executeApprovedPlan({
    required AIBatchOrganizationPlan plan,
    required Directory baseDirectory,
  }) async {
    if (!await baseDirectory.exists()) {
      await baseDirectory.create(recursive: true);
    }

    int movedCount = 0;

    for (final suggestion in plan.suggestions) {
      if (!suggestion.isAccepted) continue;

      final targetDir = Directory('${baseDirectory.path}/${suggestion.destinationFolder}');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      for (final fileName in suggestion.fileNames) {
        final sourceFile = File('${baseDirectory.path}/$fileName');
        if (await sourceFile.exists()) {
          var destPath = '${targetDir.path}/$fileName';
          var destFile = File(destPath);

          // Handle collision safely without overwriting
          if (await destFile.exists()) {
            final dotIdx = fileName.lastIndexOf('.');
            final base = dotIdx != -1 ? fileName.substring(0, dotIdx) : fileName;
            final ext = dotIdx != -1 ? fileName.substring(dotIdx) : '';
            int suffix = 1;
            while (await File('${targetDir.path}/$base ($suffix)$ext').exists()) {
              suffix++;
            }
            destPath = '${targetDir.path}/$base ($suffix)$ext';
            destFile = File(destPath);
          }

          try {
            await sourceFile.rename(destPath);
            movedCount++;
          } catch (_) {
            // If cross-device rename fails, copy and delete safely
            try {
              await sourceFile.copy(destPath);
              await sourceFile.delete();
              movedCount++;
            } catch (_) {}
          }
        }
      }
    }

    return movedCount;
  }
}
