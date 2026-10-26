import 'chunk.dart';

/// File Manifest representing the whole distribution job.
class Manifest {
  final String fileId; // UUID
  final String fileName;
  final int fileSize;
  final String mimeType; // detected MIME type
  final int chunkSize;
  final int chunkCount;
  final String fileSha256;
  final List<ChunkMeta> chunks;

  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  const Manifest({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.chunkSize,
    required this.chunkCount,
    required this.fileSha256,
    required this.chunks,
  });

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        'chunkSize': chunkSize,
        'chunkCount': chunkCount,
        'fileSha256': fileSha256,
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
        fileId: json['fileId'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        mimeType: (json['mimeType'] as String?) ?? 'application/octet-stream',
        chunkSize: (json['chunkSize'] as num).toInt(),
        chunkCount: (json['chunkCount'] as num).toInt(),
        fileSha256: json['fileSha256'] as String,
        chunks: (json['chunks'] as List<dynamic>)
            .map((e) => ChunkMeta.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
