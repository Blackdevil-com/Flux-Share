import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/transfer.dart';
import '../transfer/transfer_engine.dart';

/// Real transfer repository managing active transfers and persisting transfer history to disk.
/// No simulated progress, no fake completion.
class TransferRepository {
  static final TransferRepository _instance = TransferRepository._internal();
  factory TransferRepository() => _instance;
  TransferRepository._internal();

  final Map<String, Transfer> _activeTransfers = {};
  final List<Transfer> _transferHistory = [];
  final Map<String, StreamController<Transfer>> _controllers = {};
  final Map<String, TransferEngine> _activeEngines = {};

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final file = await _getStorageFile();
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final list = jsonDecode(jsonStr) as List<dynamic>;
        _transferHistory.clear();
        for (final item in list) {
          _transferHistory.add(Transfer.fromMap(item as Map<String, dynamic>));
        }
      }
      _isInitialized = true;
    } catch (_) {
      _isInitialized = true;
    }
  }

  /// Registers an active TransferEngine so UI can control pause/resume/cancel.
  void registerEngine(String transferId, TransferEngine engine) {
    _activeEngines[transferId] = engine;
  }

  TransferEngine? getEngine(String transferId) => _activeEngines[transferId];

  Future<List<Transfer>> getActiveTransfers() async {
    await init();
    return _activeTransfers.values.toList();
  }

  Future<List<Transfer>> getTransferHistory() async {
    await init();
    return List.unmodifiable(_transferHistory.reversed);
  }

  Stream<Transfer> getTransferStream(String transferId) {
    if (!_controllers.containsKey(transferId)) {
      _controllers[transferId] = StreamController<Transfer>.broadcast();
    }
    return _controllers[transferId]!.stream;
  }

  /// Alias for backward compatibility with TransfersScreen
  Stream<Transfer> simulateTransferProgress(String transferId) => getTransferStream(transferId);

  void updateTransfer(Transfer transfer) {
    _controllers[transfer.id]?.add(transfer);

    if (transfer.status == TransferStatus.completed ||
        transfer.status == TransferStatus.failed ||
        transfer.status == TransferStatus.cancelled) {
      _activeTransfers.remove(transfer.id);
      _transferHistory.removeWhere((t) => t.id == transfer.id);
      _transferHistory.add(transfer);
      _persistHistory();

      // Close controller after terminal event delivery to prevent memory leak
      Future.delayed(const Duration(milliseconds: 500), () {
        _controllers[transfer.id]?.close();
        _controllers.remove(transfer.id);
      });
    } else {
      _activeTransfers[transfer.id] = transfer;
    }
  }

  Future<void> pauseTransfer(String transferId) async {
    final engine = _activeEngines[transferId];
    if (engine != null) {
      engine.pause();
    }
    final current = _activeTransfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.paused,
        transferSpeedMbPerSec: 0.0,
      );
      updateTransfer(updated);
    }
  }

  Future<void> resumeTransfer(String transferId) async {
    final engine = _activeEngines[transferId];
    if (engine != null) {
      engine.resume();
    }
    final current = _activeTransfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.transferring,
      );
      updateTransfer(updated);
    }
  }

  Future<void> cancelTransfer(String transferId) async {
    final engine = _activeEngines[transferId];
    if (engine != null) {
      await engine.cancel();
      _activeEngines.remove(transferId);
    }
    final current = _activeTransfers[transferId];
    if (current != null) {
      final updated = current.copyWith(
        status: TransferStatus.cancelled,
        transferSpeedMbPerSec: 0.0,
      );
      updateTransfer(updated);
    }
  }

  Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/fluxshare_transfer_history.json');
  }

  Future<void> _persistHistory() async {
    try {
      final file = await _getStorageFile();
      final list = _transferHistory.map((t) => t.toMap()).toList();
      await file.writeAsString(jsonEncode(list), flush: true);
    } catch (_) {}
  }
}
