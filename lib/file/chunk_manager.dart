import 'dart:async';
import 'dart:io';

/// Manages physical chunk reading, writing, and preallocation at exact byte offsets.
class ChunkManager {
  /// Preallocates destination file on disk.
  static Future<void> preallocateFile(File destFile, int fileSize) async {
    final parent = destFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final raf = await destFile.open(mode: FileMode.write);
    try {
      await raf.truncate(fileSize);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// Reads a specific chunk slice from a file on disk for serving/forwarding.
  static Future<List<int>> readChunk(File file, int offset, int length) async {
    if (!await file.exists()) {
      throw FileSystemException('Source file does not exist', file.path);
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }
}

/// A serialized writer session for writing downloaded chunks safely into a destination file.
/// Chaining writes prevents file-pointer races when multiple workers complete chunks concurrently.
class ChunkWriterSession {
  final File file;
  final int totalSize;
  RandomAccessFile? _raf;
  Future<void> _writeQueue = Future.value();
  bool _isOpen = false;

  ChunkWriterSession({required this.file, required this.totalSize});

  /// Opens the file for writing and preallocates space.
  Future<void> open() async {
    if (_isOpen) return;
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    _raf = await file.open(mode: FileMode.write);
    await _raf!.truncate(totalSize);
    await _raf!.flush();
    _isOpen = true;
  }

  /// Safely writes verified chunk buffers sequentially at [offset] in a single disk operation.
  Future<void> writeVerifiedChunk(int offset, List<List<int>> buffers) {
    if (!_isOpen || _raf == null) {
      return Future.error(StateError('Writer session is not open'));
    }

    final completer = Completer<void>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        if (_raf != null && _isOpen) {
          await _raf!.setPosition(offset);
          for (final buf in buffers) {
            await _raf!.writeFrom(buf);
          }
          await _raf!.flush();
        }
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  /// Sequentially writes a chunk at [offset] with thread-safe file positioning.
  Future<void> writeChunk(int offset, List<int> bytes) {
    if (!_isOpen || _raf == null) {
      return Future.error(StateError('Writer session is not open'));
    }

    // Chain onto the write queue to ensure serialized file-pointer seeks
    final completer = Completer<void>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        if (_raf != null && _isOpen) {
          await _raf!.setPosition(offset);
          await _raf!.writeFrom(bytes);
          await _raf!.flush();
        }
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    return completer.future;
  }

  /// Flushes and closes the file handle.
  Future<void> close({bool truncateToExactSize = true}) async {
    if (!_isOpen) return;
    _isOpen = false;
    try {
      await _writeQueue; // Wait for any pending write to finish
    } catch (_) {}
    if (_raf != null) {
      try {
        if (truncateToExactSize) {
          await _raf!.truncate(totalSize);
        }
        await _raf!.flush();
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
  }
}
