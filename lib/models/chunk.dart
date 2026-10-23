/// Chunk metadata and lifecycle state according to canonical specification.
class ChunkMeta {
  final int chunkId;
  final int offset;
  final int length;
  final String sha256;

  const ChunkMeta({
    required this.chunkId,
    required this.offset,
    required this.length,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
        'chunkId': chunkId,
        'offset': offset,
        'length': length,
        'sha256': sha256,
      };

  factory ChunkMeta.fromJson(Map<String, dynamic> json) => ChunkMeta(
        chunkId: json['chunkId'] as int,
        offset: (json['offset'] as num).toInt(),
        length: (json['length'] as num).toInt(),
        sha256: json['sha256'] as String,
      );
}

/// Lifecycle states of a chunk during transfer:
/// MISSING -> REQUESTED -> TRANSFERRING -> COMPLETED
/// Failure returns to MISSING so retries remain possible.
enum ChunkState {
  missing,
  requested,
  transferring,
  completed,
  failed,
}
