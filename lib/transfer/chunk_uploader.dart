import 'dart:async';
import 'dart:io';
import '../file/chunk_manager.dart';
import '../models/chunk.dart';

/// Manages chunk uploads, tracking total bytes served by this peer
/// to separate coordinator upload volume from cooperative forwarding volume.
class ChunkUploader {
  int _totalBytesUploaded = 0;
  final _uploadStreamController = StreamController<int>.broadcast();

  int get totalBytesUploaded => _totalBytesUploaded;
  Stream<int> get uploadStream => _uploadStreamController.stream;

  /// Reads and serves chunk bytes from [sourceFile], verifying chunk exists and is available.
  Future<List<int>> serveChunk({
    required File sourceFile,
    required ChunkMeta chunk,
  }) async {
    final bytes = await ChunkManager.readChunk(sourceFile, chunk.offset, chunk.length);
    _totalBytesUploaded += bytes.length;
    _uploadStreamController.add(bytes.length);
    return bytes;
  }

  void reset() {
    _totalBytesUploaded = 0;
  }

  void dispose() {
    _uploadStreamController.close();
  }
}
