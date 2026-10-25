import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/manifest.dart';
import '../models/peer.dart';
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

  String? _primaryFileId;
  Manifest? get currentManifest =>
      (_primaryFileId != null ? _manifests[_primaryFileId] : null) ??
      _manifests.values.firstOrNull;
  File? get currentSourceFile =>
      (_primaryFileId != null ? _sourceFiles[_primaryFileId] : null) ??
      _sourceFiles.values.firstOrNull;
  final Set<int> verifiedChunks = <int>{};
  final Map<String, PeerInfo> knownPeers = <String, PeerInfo>{};

  final List<WebSocketChannel> _activeWsClients = [];
  final List<ControlMessageHandler> _controlListeners = [];

  void setManifest(Manifest manifest, File file) {
    _primaryFileId = manifest.fileId;
    _manifests[manifest.fileId] = manifest;
    _sourceFiles[manifest.fileId] = file;
    final fileChunks = _verifiedChunksByFile.putIfAbsent(manifest.fileId, () => <int>{});
    fileChunks.addAll(manifest.chunks.map((c) => c.chunkId));
    verifiedChunks.addAll(manifest.chunks.map((c) => c.chunkId));
  }

  void setBatchManifests(List<({Manifest manifest, File file})> batch) {
    for (final item in batch) {
      setManifest(item.manifest, item.file);
    }
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
      if (m != null) {
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
      if (_manifests.isNotEmpty) {
        final list = _manifests.values.map((m) => m.toJson()).toList();
        return Response.ok(
          jsonEncode({
            'batchId': _manifests.keys.first,
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
      if (_manifests.isNotEmpty) {
        final list = _manifests.values.map((m) => m.toJson()).toList();
        return Response.ok(
          jsonEncode({
            'batchId': _manifests.keys.first,
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
      final m = _manifests[fileId];
      if (m != null) {
        return Response.ok(
          jsonEncode(m.toJson()),
          headers: {'content-type': 'application/json'},
        );
      }
      return Response.notFound('Manifest for file $fileId not found');
    });

    // 3a. GET /file/<fileId>/chunk/<chunkId> (Multi-file isolated streaming)
    router.get('/file/<fileId>/chunk/<chunkId>', (Request request, String fileId, String chunkIdStr) async {
      final chunkId = int.tryParse(chunkIdStr);
      if (chunkId == null) {
        return Response.notFound('Invalid chunk ID');
      }

      final m = _manifests[fileId];
      final file = _sourceFiles[fileId];
      if (m == null || file == null || !await file.exists()) {
        return Response.notFound('Source file or manifest not available for file $fileId');
      }

      final fileChunks = _verifiedChunksByFile[fileId] ?? verifiedChunks;
      if (!fileChunks.contains(chunkId)) {
        return Response.notFound('Chunk $chunkId for file $fileId not available on this peer');
      }

      final chunk = m.chunks.firstWhere(
        (c) => c.chunkId == chunkId,
        orElse: () => throw Exception('Not found'),
      );

      try {
        final stream = file.openRead(chunk.offset, chunk.offset + chunk.length);
        return Response.ok(
          stream,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '${chunk.length}',
            'content-disposition': 'attachment; filename="chunk_${fileId}_$chunkId"',
          },
        );
      } catch (e) {
        return Response.internalServerError(body: 'Error reading chunk: $e');
      }
    });

    // 3b. GET /chunk/<chunkId> (Single-file legacy streaming)
    router.get('/chunk/<chunkId>', (Request request, String chunkIdStr) async {
      final chunkId = int.tryParse(chunkIdStr);
      if (chunkId == null) {
        return Response.notFound('Invalid chunk ID');
      }

      final m = currentManifest;
      final file = currentSourceFile;
      if (m == null || file == null || !await file.exists()) {
        return Response.notFound('Source file or manifest not available');
      }

      if (!verifiedChunks.contains(chunkId)) {
        return Response.notFound('Chunk $chunkId not available on this peer');
      }

      final chunk = m.chunks.firstWhere(
        (c) => c.chunkId == chunkId,
        orElse: () => throw Exception('Not found'),
      );

      try {
        // Zero-buffer direct disk streaming to socket
        final stream = file.openRead(chunk.offset, chunk.offset + chunk.length);

        return Response.ok(
          stream,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '${chunk.length}',
            'content-disposition': 'attachment; filename="chunk_$chunkId"',
          },
        );
      } catch (e) {
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

      channel.stream.listen(
        (data) {
          try {
            final parsed = jsonDecode(data as String) as Map<String, dynamic>;
            for (final listener in List.of(_controlListeners)) {
              listener(parsed);
            }
          } catch (_) {}
        },
        onDone: () {
          _activeWsClients.remove(channel);
        },
        onError: (_) {
          _activeWsClients.remove(channel);
        },
      );
    });

    router.get('/ws', wsHandler);

    final handler = const Pipeline()
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
    for (final client in _activeWsClients) {
      try {
        client.sink.close();
      } catch (_) {}
    }
    _activeWsClients.clear();
    _controlListeners.clear();
    _manifests.clear();
    _sourceFiles.clear();
    _verifiedChunksByFile.clear();
    verifiedChunks.clear();
    _primaryFileId = null;
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }
}
