import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/chunk.dart';
import '../models/connected_receiver.dart';
import '../models/device.dart';
import '../models/manifest.dart';
import '../models/peer.dart';
import '../services/managed_temporary_file_service.dart';
import 'network_utils.dart';

typedef ControlMessageHandler = void Function(Map<String, dynamic> message);

/// Embedded P2P server running on 0.0.0.0.
/// Hosts HTTP endpoints (/health, /manifest, /chunk/<id>, /peer, /room/join) and WebSocket (/ws).
class LocalServer {
  static final LocalServer _instance = LocalServer._internal();
  factory LocalServer() => _instance;
  LocalServer._internal();

  HttpServer? _server;
  int _port = 0;
  int get port => _port;
  bool get isRunning => _server != null;
  int get activeControlSocketsCount => _activeWsClients.length;

  String localPeerId = 'Peer-${DateTime.now().millisecondsSinceEpoch % 10000}';
  String localDeviceName = 'FluxShare Device';
  String platform = Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'unknown');

  final Map<String, Manifest> _manifests = <String, Manifest>{};
  final Map<String, File> _sourceFiles = <String, File>{};
  final Map<String, Set<int>> _verifiedChunksByFile = <String, Set<int>>{};

  String? _activeBatchId;
  String? get activeBatchId => _activeBatchId;
  bool get hasActiveBatch => _activeBatchId != null && _manifests.isNotEmpty;

  String? _primaryFileId;
  Manifest? get currentManifest =>
      _activeBatchId == null
          ? null
          : ((_primaryFileId != null ? _manifests[_primaryFileId] : null) ??
              _manifests.values.firstOrNull);
  File? get currentSourceFile =>
      _activeBatchId == null
          ? null
          : ((_primaryFileId != null ? _sourceFiles[_primaryFileId] : null) ??
              _sourceFiles.values.firstOrNull);
  final Set<int> verifiedChunks = <int>{};
  final Map<String, PeerInfo> knownPeers = <String, PeerInfo>{};

  final List<WebSocketChannel> _activeWsClients = [];
  final List<ControlMessageHandler> _controlListeners = [];

  bool _transferStarted = false;
  bool get isTransferStarted => _transferStarted;

  final Map<String, ConnectedReceiver> _connectedReceivers = {};
  final Map<WebSocketChannel, String> _channelPeerMap = {};
  final StreamController<List<ConnectedReceiver>> _connectedReceiversController =
      StreamController<List<ConnectedReceiver>>.broadcast();

  List<ConnectedReceiver> get connectedReceivers =>
      List.unmodifiable(_connectedReceivers.values);
  Stream<List<ConnectedReceiver>> get connectedReceiversStream =>
      _connectedReceiversController.stream;

  void broadcastTransferStart({
    required String sessionId,
    List<String>? authorizedReceivers,
  }) {
    _transferStarted = true;
    broadcastMessage({
      'type': 'TRANSFER_START',
      'sessionId': sessionId,
      if (authorizedReceivers != null) 'authorizedReceivers': authorizedReceivers,
    });
  }

  final Map<String, Set<String>> _servedChunksByPeer = {};
  final Map<String, int> _bytesServedByPeer = {};

  void updateReceiver(ConnectedReceiver receiver) {
    _connectedReceivers[receiver.peerId] = receiver;
    _connectedReceiversController.add(connectedReceivers);
  }

  void clearReceivers({bool notify = true}) {
    _connectedReceivers.clear();
    _channelPeerMap.clear();
    _servedChunksByPeer.clear();
    _bytesServedByPeer.clear();
    _transferStarted = false;
    if (notify) {
      _connectedReceiversController.add([]);
    }
  }

  /// Replaces the active batch atomically. Validates items, clears previous batch data,
  /// and establishes the new batch manifest and source file mappings.
  void replaceBatchManifests(String batchId, List<({Manifest manifest, File file})> batch) {
    if (batch.isEmpty) {
      throw ArgumentError('Batch cannot be empty');
    }

    final newManifests = <String, Manifest>{};
    final newSourceFiles = <String, File>{};
    final newVerifiedChunksByFile = <String, Set<int>>{};
    final newVerifiedChunks = <int>{};

    for (final item in batch) {
      final m = item.manifest;
      final f = item.file;
      if (newManifests.containsKey(m.fileId)) {
        throw ArgumentError('Duplicate fileId in batch: ${m.fileId}');
      }
      newManifests[m.fileId] = m;
      newSourceFiles[m.fileId] = f;
      final chunks = m.chunks.map((c) => c.chunkId).toSet();
      newVerifiedChunksByFile[m.fileId] = chunks;
      newVerifiedChunks.addAll(chunks);
    }

    _manifests.clear();
    _manifests.addAll(newManifests);

    _sourceFiles.clear();
    _sourceFiles.addAll(newSourceFiles);

    _verifiedChunksByFile.clear();
    _verifiedChunksByFile.addAll(newVerifiedChunksByFile);

    verifiedChunks.clear();
    verifiedChunks.addAll(newVerifiedChunks);

    _primaryFileId = batch.first.manifest.fileId;
    _activeBatchId = batchId;
  }

  /// Completely clears active batch metadata, manifests, source files, and chunk indexes.
  void clearBatch({bool notify = true}) {
    clearReceivers(notify: notify);
    _activeBatchId = null;
    _primaryFileId = null;
    _manifests.clear();
    _sourceFiles.clear();
    _verifiedChunksByFile.clear();
    verifiedChunks.clear();
    _servedChunksByPeer.clear();
    _bytesServedByPeer.clear();
  }

  void _notifyControlListeners(Map<String, dynamic> msg) {
    for (final listener in List.of(_controlListeners)) {
      try {
        listener(msg);
      } catch (_) {}
    }
  }

  @visibleForTesting
  void notifyControlListenersForTesting(Map<String, dynamic> msg) {
    _notifyControlListeners(msg);
  }

  void _recordChunkServed({
    required Request request,
    required String fileId,
    required int chunkId,
    required int chunkBytes,
  }) {
    final headerPeerId = request.headers['x-peer-id'] ?? request.headers['X-Peer-Id'];

    String? targetPeerId = headerPeerId;
    if (targetPeerId == null || !_connectedReceivers.containsKey(targetPeerId)) {
      if (_connectedReceivers.length == 1) {
        targetPeerId = _connectedReceivers.keys.first;
      } else {
        String? clientIp;
        final connInfo = request.context['shelf.io.connection_info'];
        if (connInfo is HttpConnectionInfo) {
          clientIp = connInfo.remoteAddress.address;
        }
        if (clientIp != null) {
          try {
            final match = _connectedReceivers.values.firstWhere(
              (r) => r.ip == clientIp,
            );
            targetPeerId = match.peerId;
          } catch (_) {}
        }
      }
    }

    if (targetPeerId == null) {
      targetPeerId = headerPeerId ?? 'receiver_${_connectedReceivers.length + 1}';
      _connectedReceivers[targetPeerId] = ConnectedReceiver(
        peerId: targetPeerId,
        deviceName: 'Receiver',
        platform: DevicePlatform.Android,
        status: ReceiverStatus.receiving,
        progressPercent: 0.0,
        bytesReceived: 0,
        lastSeen: DateTime.now(),
      );
    }

    final chunkKey = '$fileId:$chunkId';
    final servedSet = _servedChunksByPeer.putIfAbsent(targetPeerId, () => <String>{});
    final isNewChunk = servedSet.add(chunkKey);

    if (isNewChunk) {
      final currentBytes = (_bytesServedByPeer[targetPeerId] ?? 0) + chunkBytes;
      _bytesServedByPeer[targetPeerId] = currentBytes;

      final totalBytes = _manifests.values.fold(0, (sum, m) => sum + m.fileSize);
      final pct = totalBytes > 0
          ? ((currentBytes / totalBytes) * 100.0).clamp(0.0, 100.0)
          : 0.0;

      final existing = _connectedReceivers[targetPeerId];
      if (existing != null) {
        final effectiveBytes = currentBytes > existing.bytesReceived ? currentBytes : existing.bytesReceived;
        final effectivePct = pct > existing.progressPercent ? pct : existing.progressPercent;
        final isComplete = effectivePct >= 100.0;

        _connectedReceivers[targetPeerId] = existing.copyWith(
          status: isComplete ? ReceiverStatus.completed : ReceiverStatus.receiving,
          progressPercent: effectivePct,
          bytesReceived: effectiveBytes,
          lastSeen: DateTime.now(),
        );
        _connectedReceiversController.add(connectedReceivers);

        _notifyControlListeners({
          'type': 'TRANSFER_PROGRESS',
          'sessionId': _activeBatchId ?? '',
          'peerId': targetPeerId,
          'percent': effectivePct,
          'bytesTransferred': effectiveBytes,
          'totalBytes': totalBytes,
        });
      }
    }
  }

  /// Sets single manifest for backward compatibility by replacing the active batch.
  void setManifest(Manifest manifest, File file) {
    replaceBatchManifests(manifest.fileId, [(manifest: manifest, file: file)]);
  }

  /// Sets multiple batch manifests, replacing any previously active batch.
  void setBatchManifests(List<({Manifest manifest, File file})> batch) {
    if (batch.isEmpty) {
      clearBatch();
      return;
    }
    replaceBatchManifests('batch_${DateTime.now().millisecondsSinceEpoch}', batch);
  }

  void setVerifiedChunks(Set<int> chunks, {String? fileId}) {
    if (fileId != null) {
      final fileChunks = _verifiedChunksByFile.putIfAbsent(fileId, () => <int>{});
      fileChunks.clear();
      fileChunks.addAll(chunks);
    }
    verifiedChunks.clear();
    verifiedChunks.addAll(chunks);
  }

  void markChunkAvailable(int chunkId, {String? fileId}) {
    final targetFileId = fileId ?? currentManifest?.fileId;
    if (targetFileId != null) {
      _verifiedChunksByFile.putIfAbsent(targetFileId, () => <int>{}).add(chunkId);
    }
    verifiedChunks.add(chunkId);
    broadcastMessage({
      'type': 'CHUNK_AVAILABLE',
      'peerId': localPeerId,
      if (targetFileId != null) 'fileId': targetFileId,
      'chunkId': chunkId,
    });
  }

  void addControlListener(ControlMessageHandler handler) {
    _controlListeners.add(handler);
  }

  void removeControlListener(ControlMessageHandler handler) {
    _controlListeners.remove(handler);
  }

  void broadcastMessage(Map<String, dynamic> message) {
    final text = jsonEncode(message);
    for (final client in List.of(_activeWsClients)) {
      try {
        client.sink.add(text);
      } catch (_) {}
    }
  }

  /// Starts the HTTP + WebSocket server bound strictly to 0.0.0.0.
  Future<int> start({int preferredPort = 8080}) async {
    if (_server != null) return _port;

    final router = Router();

    // 1. GET /health
    router.get('/health', (Request request) {
      final data = {
        'status': 'ok',
        'peerId': localPeerId,
        'deviceName': localDeviceName,
        'platform': platform,
        'version': '1.0.0',
      };
      return Response.ok(
        jsonEncode(data),
        headers: {'content-type': 'application/json'},
      );
    });

    // 2a. GET /manifest (single manifest / primary file)
    router.get('/manifest', (Request request) {
      final m = currentManifest;
      if (m != null && _activeBatchId != null) {
        return Response.ok(
          jsonEncode(m.toJson()),
          headers: {'content-type': 'application/json'},
        );
      } else {
        return Response.notFound(
          jsonEncode({'error': 'MANIFEST_NOT_READY', 'message': 'Host has not selected a file yet'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 2b. GET /manifests or /batch-manifest (full batch manifest)
    router.get('/manifests', (Request request) {
      if (_manifests.isNotEmpty && _activeBatchId != null) {
        final list = _manifests.values.map((m) => m.toJson()).toList();
        return Response.ok(
          jsonEncode({
            'batchId': _activeBatchId!,
            'totalFiles': _manifests.length,
            'totalBytes': _manifests.values.fold(0, (sum, m) => sum + m.fileSize),
            'manifests': list,
          }),
          headers: {'content-type': 'application/json'},
        );
      } else {
        return Response.notFound(
          jsonEncode({'error': 'MANIFEST_NOT_READY', 'message': 'No manifests available'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    router.get('/batch-manifest', (Request request) {
      if (_manifests.isNotEmpty && _activeBatchId != null) {
        final list = _manifests.values.map((m) => m.toJson()).toList();
        return Response.ok(
          jsonEncode({
            'batchId': _activeBatchId!,
            'totalFiles': _manifests.length,
            'totalBytes': _manifests.values.fold(0, (sum, m) => sum + m.fileSize),
            'manifests': list,
          }),
          headers: {'content-type': 'application/json'},
        );
      } else {
        return Response.notFound(
          jsonEncode({'error': 'MANIFEST_NOT_READY', 'message': 'No manifests available'}),
          headers: {'content-type': 'application/json'},
        );
      }
    });

    // 2c. GET /file/<fileId>/manifest
    router.get('/file/<fileId>/manifest', (Request request, String fileId) {
      if (_activeBatchId == null) {
        debugPrint('[FluxShare-Server] [404] Manifest rejected: No active batch');
        return Response.notFound(
          jsonEncode({'error': 'MANIFEST_NOT_READY', 'message': 'No active batch'}),
          headers: {'content-type': 'application/json'},
        );
      }
      final decodedFileId = Uri.decodeComponent(fileId);
      final m = _manifests[fileId] ?? _manifests[decodedFileId];
      if (m != null) {
        return Response.ok(
          jsonEncode(m.toJson()),
          headers: {'content-type': 'application/json'},
        );
      }
      debugPrint('[FluxShare-Server] [404] Manifest not found for fileId: $fileId (decoded: $decodedFileId). Available fileIds: ${_manifests.keys.toList()}');
      return Response.notFound(
        jsonEncode({'error': 'FILE_NOT_FOUND', 'message': 'Manifest for file $fileId not found'}),
        headers: {'content-type': 'application/json'},
      );
    });

    // 3a. GET /file/<fileId>/chunk/<chunkId> (Multi-file isolated streaming)
    router.get('/file/<fileId>/chunk/<chunkId>', (Request request, String fileId, String chunkIdStr) async {
      if (_activeBatchId == null) {
        debugPrint('[FluxShare-Server] [404] Chunk rejected: No active batch');
        return Response.notFound('No active batch');
      }
      final chunkId = int.tryParse(chunkIdStr);
      if (chunkId == null) {
        debugPrint('[FluxShare-Server] [404] Chunk rejected: Invalid chunk ID "$chunkIdStr"');
        return Response.notFound('Invalid chunk ID');
      }

      final decodedFileId = Uri.decodeComponent(fileId);
      final m = _manifests[fileId] ?? _manifests[decodedFileId];
      final file = _sourceFiles[fileId] ?? _sourceFiles[decodedFileId];
      final activeFileId = _manifests.containsKey(fileId) ? fileId : decodedFileId;

      if (m == null || file == null || !await file.exists()) {
        final exists = file != null && await file.exists();
        debugPrint('[FluxShare-Server] [404] Chunk rejected: Source file or manifest not available for file $fileId (decoded: $decodedFileId, manifestFound: ${m != null}, fileExists: $exists). Available: ${_manifests.keys.toList()}');
        return Response.notFound('Source file or manifest not available for file $fileId');
      }

      final fileChunks = _verifiedChunksByFile[activeFileId] ?? _verifiedChunksByFile[fileId] ?? verifiedChunks;
      if (!fileChunks.contains(chunkId)) {
        debugPrint('[FluxShare-Server] [404] Chunk rejected: Chunk $chunkId for file $fileId not available on this peer. Verified count: ${fileChunks.length}');
        return Response.notFound('Chunk $chunkId for file $fileId not available on this peer');
      }

      final ChunkMeta chunk;
      try {
        chunk = m.chunks.firstWhere((c) => c.chunkId == chunkId);
      } catch (_) {
        debugPrint('[FluxShare-Server] [404] Chunk $chunkId not found in manifest for file $fileId');
        return Response.notFound('Chunk $chunkId not found in manifest');
      }

      final activeBatchId = _activeBatchId ?? '';
      ManagedTemporaryFileService.instance.registerActiveUse(
        activeBatchId,
        file.path,
      );
      try {
        final rawStream = file.openRead(chunk.offset, chunk.offset + chunk.length);
        final stream = rawStream.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (data, sink) => sink.add(data),
            handleDone: (sink) {
              unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
                activeBatchId,
                file.path,
              ));
              sink.close();
            },
            handleError: (error, stackTrace, sink) {
              unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
                activeBatchId,
                file.path,
              ));
              sink.addError(error, stackTrace);
            },
          ),
        );
        _recordChunkServed(
          request: request,
          fileId: activeFileId,
          chunkId: chunkId,
          chunkBytes: chunk.length,
        );
        return Response.ok(
          stream,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '${chunk.length}',
            'content-disposition': 'attachment; filename="chunk_${activeFileId}_$chunkId"',
          },
        );
      } catch (e) {
        unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
          activeBatchId,
          file.path,
        ));
        debugPrint('[FluxShare-Server] [500] Error reading chunk $chunkId for file $fileId: $e');
        return Response.internalServerError(body: 'Error reading chunk: $e');
      }
    });

    // 3b. GET /chunk/<chunkId> (Single-file legacy streaming)
    router.get('/chunk/<chunkId>', (Request request, String chunkIdStr) async {
      if (_activeBatchId == null) {
        debugPrint('[FluxShare-Server] [404] Legacy chunk rejected: No active batch');
        return Response.notFound('No active batch');
      }
      final chunkId = int.tryParse(chunkIdStr);
      if (chunkId == null) {
        debugPrint('[FluxShare-Server] [404] Legacy chunk rejected: Invalid chunk ID "$chunkIdStr"');
        return Response.notFound('Invalid chunk ID');
      }

      final m = currentManifest;
      final file = currentSourceFile;
      if (m == null || file == null || !await file.exists()) {
        debugPrint('[FluxShare-Server] [404] Legacy chunk rejected: Source file or manifest not available');
        return Response.notFound('Source file or manifest not available');
      }

      if (!verifiedChunks.contains(chunkId)) {
        debugPrint('[FluxShare-Server] [404] Legacy chunk rejected: Chunk $chunkId not available on this peer');
        return Response.notFound('Chunk $chunkId not available on this peer');
      }

      final ChunkMeta chunk;
      try {
        chunk = m.chunks.firstWhere((c) => c.chunkId == chunkId);
      } catch (_) {
        debugPrint('[FluxShare-Server] [404] Legacy chunk $chunkId not found in manifest');
        return Response.notFound('Chunk $chunkId not found');
      }

      final activeBatchId = _activeBatchId ?? '';
      ManagedTemporaryFileService.instance.registerActiveUse(
        activeBatchId,
        file.path,
      );
      try {
        // Zero-buffer direct disk streaming to socket
        final rawStream = file.openRead(chunk.offset, chunk.offset + chunk.length);
        final stream = rawStream.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (data, sink) => sink.add(data),
            handleDone: (sink) {
              unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
                activeBatchId,
                file.path,
              ));
              sink.close();
            },
            handleError: (error, stackTrace, sink) {
              unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
                activeBatchId,
                file.path,
              ));
              sink.addError(error, stackTrace);
            },
          ),
        );
        _recordChunkServed(
          request: request,
          fileId: m.fileId,
          chunkId: chunkId,
          chunkBytes: chunk.length,
        );
        return Response.ok(
          stream,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '${chunk.length}',
            'content-disposition': 'attachment; filename="chunk_$chunkId"',
          },
        );
      } catch (e) {
        unawaited(ManagedTemporaryFileService.instance.releaseActiveUse(
          activeBatchId,
          file.path,
        ));
        debugPrint('[FluxShare-Server] [500] Error reading legacy chunk $chunkId: $e');
        return Response.internalServerError(body: 'Error reading chunk: $e');
      }
    });

    // 4. GET /peer
    router.get('/peer', (Request request) async {
      final localIp = await NetworkUtils.getLocalIpAddress() ?? '0.0.0.0';
      final info = PeerInfo(
        peerId: localPeerId,
        deviceName: localDeviceName,
        platform: platform,
        ip: localIp,
        httpPort: _port,
        webSocketPort: _port,
        availableChunks: Set.from(verifiedChunks),
        availableChunksByFile: Map.from(
          _verifiedChunksByFile.map((k, v) => MapEntry(k, Set<int>.from(v))),
        ),
      );
      return Response.ok(
        jsonEncode(info.toJson()),
        headers: {'content-type': 'application/json'},
      );
    });

    // 5. POST /room/join
    router.post('/room/join', (Request request) async {
      final body = await request.readAsString();
      try {
        jsonDecode(body);
        // Return active room confirmation
        return Response.ok(
          jsonEncode({'status': 'joined', 'peerId': localPeerId, 'fileId': currentManifest?.fileId}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        return Response.badRequest(body: 'Invalid join body: $e');
      }
    });

    // 6. WebSocket /ws
    final wsHandler = webSocketHandler((WebSocketChannel channel) async {
      _activeWsClients.add(channel);

      // CRITICAL RULE: On connect, immediately send the host's current peerId, address, and verified chunks
      final localIp = await NetworkUtils.getLocalIpAddress() ?? '0.0.0.0';
      final hostStateMessage = {
        'type': 'PEER_JOINED',
        'peerId': localPeerId,
        'deviceName': localDeviceName,
        'platform': platform,
        'ip': localIp,
        'httpPort': _port,
        'webSocketPort': _port,
        'availableChunks': verifiedChunks.toList(),
      };
      channel.sink.add(jsonEncode(hostStateMessage));

      if (_transferStarted) {
        channel.sink.add(jsonEncode({
          'type': 'TRANSFER_START',
          'sessionId': _activeBatchId ?? 'session',
        }));
      }

      channel.stream.listen(
        (data) {
          try {
            final parsed = jsonDecode(data as String) as Map<String, dynamic>;
            final type = parsed['type'] as String?;
            final peerId = parsed['peerId'] as String?;

            if (peerId != null) {
              _channelPeerMap[channel] = peerId;
            }

            if (type == 'RECEIVER_JOINED' && peerId != null) {
              final deviceName = parsed['deviceName'] as String? ?? 'Receiver';
              final platStr = parsed['platform'] as String? ?? '';
              final receiverIp = parsed['ip'] as String?;
              _connectedReceivers[peerId] = ConnectedReceiver(
                peerId: peerId,
                deviceName: deviceName,
                platform: DevicePlatform.fromString(platStr),
                ip: receiverIp,
                status: ReceiverStatus.connected,
                progressPercent: 0.0,
                bytesReceived: 0,
                lastSeen: DateTime.now(),
              );
              _connectedReceiversController.add(connectedReceivers);

              if (_transferStarted) {
                channel.sink.add(jsonEncode({
                  'type': 'TRANSFER_START',
                  'sessionId': _activeBatchId ?? 'session',
                }));
              }
            } else if (type == 'RECEIVER_READY' && peerId != null) {
              final existing = _connectedReceivers[peerId];
              final deviceName = parsed['deviceName'] as String? ?? existing?.deviceName ?? 'Receiver';
              final platStr = parsed['platform'] as String? ?? '';
              final receiverIp = parsed['ip'] as String? ?? existing?.ip;
              _connectedReceivers[peerId] = (existing ?? ConnectedReceiver(
                peerId: peerId,
                deviceName: deviceName,
                platform: DevicePlatform.fromString(platStr),
                ip: receiverIp,
                lastSeen: DateTime.now(),
              )).copyWith(
                status: ReceiverStatus.ready,
                lastSeen: DateTime.now(),
              );
              _connectedReceiversController.add(connectedReceivers);

              if (_transferStarted) {
                channel.sink.add(jsonEncode({
                  'type': 'TRANSFER_START',
                  'sessionId': _activeBatchId ?? 'session',
                }));
              }
            } else if (type == 'TRANSFER_PROGRESS') {
              final activePeerId = peerId ?? _channelPeerMap[channel] ?? 'receiver';
              final pct = (parsed['percent'] as num?)?.toDouble() ?? 0.0;
              final bytes = (parsed['bytesTransferred'] as num?)?.toInt() ?? 0;
              final existing = _connectedReceivers[activePeerId];
              if (existing != null && existing.status != ReceiverStatus.failed) {
                _connectedReceivers[activePeerId] = existing.copyWith(
                  status: pct >= 100.0 ? ReceiverStatus.completed : ReceiverStatus.receiving,
                  progressPercent: pct,
                  bytesReceived: bytes,
                  lastSeen: DateTime.now(),
                );
                _connectedReceiversController.add(connectedReceivers);
              }
            } else if (type == 'TRANSFER_COMPLETED') {
              final activePeerId = peerId ?? _channelPeerMap[channel] ?? 'receiver';
              final existing = _connectedReceivers[activePeerId];
              if (existing != null) {
                _connectedReceivers[activePeerId] = existing.copyWith(
                  status: ReceiverStatus.completed,
                  progressPercent: 100.0,
                  lastSeen: DateTime.now(),
                );
                _connectedReceiversController.add(connectedReceivers);
              }
            } else if (type == 'RECEIVER_FAILED') {
              final activePeerId = peerId ?? _channelPeerMap[channel] ?? 'receiver';
              final error = parsed['error'] as String? ?? 'Receiver failed';
              final existing = _connectedReceivers[activePeerId];
              if (existing != null) {
                _connectedReceivers[activePeerId] = existing.copyWith(
                  status: ReceiverStatus.failed,
                  errorMessage: error,
                  lastSeen: DateTime.now(),
                );
                _connectedReceiversController.add(connectedReceivers);
              }
            }

            _notifyControlListeners(parsed);
          } catch (_) {}
        },
        onDone: () {
          final peerId = _channelPeerMap.remove(channel);
          if (peerId != null) {
            final existing = _connectedReceivers[peerId];
            if (existing != null && existing.status != ReceiverStatus.completed) {
              _connectedReceivers[peerId] = existing.copyWith(
                status: ReceiverStatus.disconnected,
                lastSeen: DateTime.now(),
              );
              _connectedReceiversController.add(connectedReceivers);
            }
          }
          _activeWsClients.remove(channel);
        },
        onError: (_) {
          final peerId = _channelPeerMap.remove(channel);
          if (peerId != null) {
            final existing = _connectedReceivers[peerId];
            if (existing != null && existing.status != ReceiverStatus.completed) {
              _connectedReceivers[peerId] = existing.copyWith(
                status: ReceiverStatus.disconnected,
                lastSeen: DateTime.now(),
              );
              _connectedReceiversController.add(connectedReceivers);
            }
          }
          _activeWsClients.remove(channel);
        },
      );
    });

    router.get('/ws', wsHandler);

    final handler = const Pipeline()
        .addMiddleware((innerHandler) {
          return (Request req) async {
            final res = await innerHandler(req);
            if (res.statusCode == 404) {
              debugPrint('[FluxShare-Server] [404] method=${req.method}, path=/${req.url.path}');
            }
            return res;
          };
        })
        .addMiddleware(logRequests())
        .addHandler(router.call);

    // Bind to 0.0.0.0 explicitly
    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, preferredPort);
      _port = _server!.port;
    } catch (_) {
      // If preferred port is taken, bind to ephemeral free port
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
      _port = _server!.port;
    }

    return _port;
  }

  Future<void> stop() async {
    for (final client in List.of(_activeWsClients)) {
      try {
        await client.sink.close();
      } catch (_) {}
    }
    _activeWsClients.clear();
    _controlListeners.clear();
    clearBatch();
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }
}
