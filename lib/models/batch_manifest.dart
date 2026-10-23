import 'manifest.dart';

/// Represents a multi-file batch transfer manifest containing individual file manifests.
class BatchManifest {
  final String batchId;
  final List<Manifest> manifests;
  final int totalFiles;
  final int totalBytes;

  BatchManifest({
    required this.batchId,
    required this.manifests,
  })  : totalFiles = manifests.length,
        totalBytes = manifests.fold(0, (sum, m) => sum + m.fileSize);

  Manifest? findManifest(String fileId) {
    for (final m in manifests) {
      if (m.fileId == fileId) return m;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'totalFiles': totalFiles,
        'totalBytes': totalBytes,
        'manifests': manifests.map((m) => m.toJson()).toList(),
      };

  factory BatchManifest.fromJson(Map<String, dynamic> json) {
    final rawList = json['manifests'] as List<dynamic>? ?? [];
    final manifests = rawList
        .map((e) => Manifest.fromJson(e as Map<String, dynamic>))
        .toList();
    return BatchManifest(
      batchId: json['batchId'] as String? ?? 'batch_${DateTime.now().millisecondsSinceEpoch}',
      manifests: manifests,
    );
  }

  factory BatchManifest.fromSingleManifest(Manifest manifest) {
    return BatchManifest(
      batchId: manifest.fileId,
      manifests: [manifest],
    );
  }
}
