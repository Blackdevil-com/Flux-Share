import 'dart:async';
import '../models/models.dart';
import 'mock_data.dart';

class MockTransferRepository {
  final Map<String, Transfer> _transfers = {
    for (var t in MockData.initialTransfers) t.id: t,
  };

  final Map<String, StreamController<Transfer>> _controllers = {};

  Future<List<Transfer>> getActiveTransfers() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return _transfers.values.where((t) {
      return t.status == TransferStatus.starting ||
          t.status == TransferStatus.transferring ||
          t.status == TransferStatus.paused;
    }).toList();
  }

  Future<List<Transfer>> getTransferHistory() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return _transfers.values.where((t) {
      return t.status == TransferStatus.completed ||
          t.status == TransferStatus.failed ||
          t.status == TransferStatus.cancelled;
    }).toList();
  }

  Stream<Transfer> simulateTransferProgress(String transferId) {
    if (_controllers.containsKey(transferId)) {
      return _controllers[transferId]!.stream;
    }

    final controller = StreamController<Transfer>.broadcast();
    _controllers[transferId] = controller;

    Timer.periodic(const Duration(seconds: 1), (timer) {
      final current = _transfers[transferId];
      if (current == null ||
          current.status == TransferStatus.paused ||
          current.status == TransferStatus.cancelled ||
          current.status == TransferStatus.failed ||
          current.status == TransferStatus.completed) {
        if (current?.status == TransferStatus.completed ||
            current?.status == TransferStatus.cancelled) {
          timer.cancel();
          controller.close();
          _controllers.remove(transferId);
        }
        return;
      }

      final newProgress = (current.progressPercent + 5.0).clamp(0.0, 100.0);
      final isDone = newProgress >= 100.0;
      final newStatus = isDone ? TransferStatus.completed : TransferStatus.transferring;
      final newBytes = ((newProgress / 100.0) * current.fileInfo.sizeBytes).round();
      final speed = isDone ? 0.0 : 25.0 + (newProgress % 10);
      final remaining = isDone
          ? 0
          : ((current.fileInfo.sizeBytes - newBytes) / (speed * 1024 * 1024)).round();

      final updatedReceivers = current.receivers.map((r) {
        return r.copyWith(progressPercent: newProgress);
      }).toList();

      final totalChunks = (current.chunkStats['totalChunks'] as int?) ?? 100;
      final completedChunks = ((newProgress / 100.0) * totalChunks).round();

      final updated = current.copyWith(
        status: newStatus,
        progressPercent: newProgress,
        bytesTransferred: newBytes,
        transferSpeedMbPerSec: speed,
        remainingSeconds: remaining,
        receivers: updatedReceivers,
        chunkStats: {
          ...current.chunkStats,
          'completedChunks': completedChunks,
        },
      );

      _transfers[transferId] = updated;
      controller.add(updated);

      if (isDone) {
        timer.cancel();
        controller.close();
        _controllers.remove(transferId);
      }
    });

    return controller.stream;
  }

  Future<void> pauseTransfer(String transferId) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final current = _transfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.paused,
        transferSpeedMbPerSec: 0.0,
      );
      _transfers[transferId] = updated;
      _controllers[transferId]?.add(updated);
    }
  }

  Future<void> resumeTransfer(String transferId) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final current = _transfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.transferring,
      );
      _transfers[transferId] = updated;
      _controllers[transferId]?.add(updated);
    }
  }

  Future<void> cancelTransfer(String transferId) async {
    await Future.delayed(const Duration(milliseconds: 100));
    final current = _transfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.cancelled,
        transferSpeedMbPerSec: 0.0,
      );
      _transfers[transferId] = updated;
      _controllers[transferId]?.add(updated);
    }
  }
}
