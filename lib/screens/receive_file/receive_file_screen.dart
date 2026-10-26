import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/theme.dart';
import '../../discovery/discovery_service.dart';
import '../../file/filename_sanitizer.dart';
import '../../models/models.dart';
import '../../network/http_client.dart';
import '../../network/network_utils.dart';
import '../../network/local_server.dart';
import '../../network/websocket_service.dart';
import '../../services/storage_diagnostics_service.dart';
import '../../services/storage_path_service.dart';
import '../../transfer/batch_transfer_coordinator.dart';
import '../../transfer/transfer_session_manager.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_progress_screen.dart';

class ReceiveFileScreen extends StatefulWidget {
  const ReceiveFileScreen({super.key});

  @override
  State<ReceiveFileScreen> createState() => _ReceiveFileScreenState();
}

class _ReceiveFileScreenState extends State<ReceiveFileScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  final TextEditingController _pinController = TextEditingController();

  bool _isConnecting = false;
  bool _manifestReceived = false;
  String? _connectedPin;
  int _connectionGeneration = 0;

  FileInfo _incomingFile = const FileInfo(
    id: 'pending_file',
    name: 'Incoming File',
    sizeBytes: 0,
    formattedSize: '0 B',
    extension: '',
    type: FileType.Other,
  );
  String _senderName = "Nearby Sender";
  BatchManifest? _currentBatchManifest;
  Manifest? _currentManifest;
  DiscoveredRoom? _discoveredRoom;
  WebSocketService? _activeWsService;
  StreamSubscription? _wsSubscription;
  bool _hostTransferStarted = false;
  bool _userAcceptedTransfer = false;
  bool _transferInitiated = false;

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    if (!_transferInitiated) {
      _activeWsService?.disconnect();
    }
    _pulseController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _joinRoom() async {
    final pin = _pinController.text.trim();
    if (pin.length < 4) return;

    FocusScope.of(context).unfocus();
    final currentGen = ++_connectionGeneration;
    setState(() {
      _isConnecting = true;
    });

    try {
      final discoveryService = DiscoveryService();
      final discoveryResult = await discoveryService.discoverRoomResult(pin: pin);

      if (!mounted || _connectionGeneration != currentGen) return;

      if (discoveryResult is! DiscoverRoomSuccess) {
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
          final message = discoveryResult is DiscoverRoomTimeout
              ? 'Could not find host with PIN $pin. Ensure both devices are on the same Wi-Fi or Hotspot.'
              : 'Discovery error: ${(discoveryResult as DiscoverRoomFailure).reason}';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: AppColors.primaryBlack,
              action: SnackBarAction(
                label: 'Direct IP',
                textColor: AppColors.backgroundWhite,
                onPressed: _showDirectConnectDialog,
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      final room = discoveryResult.room;
      final httpClient = P2PHttpClient();

      // Health check before downloading manifests
      final health = await httpClient.checkHealth(room.ip, room.port);
      if (!mounted || _connectionGeneration != currentGen) {
        httpClient.close();
        return;
      }
      if (health is! HealthCheckSuccess) {
        httpClient.close();
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
          final errorMsg = health is HealthCheckUnreachable
              ? 'Discovered host at ${room.ip}:${room.port}, but HTTP connection failed. Hotspot client isolation may be blocking device-to-device traffic.'
              : 'Host health error: ${(health as HealthCheckFailure).message}';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: AppColors.primaryBlack,
              action: SnackBarAction(
                label: 'Direct IP',
                textColor: AppColors.backgroundWhite,
                onPressed: _showDirectConnectDialog,
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      BatchManifestFetchResult result;
      try {
        result = await httpClient.downloadBatchManifest(room.ip, room.port);
      } finally {
        httpClient.close();
      }

      if (!mounted || _connectionGeneration != currentGen) return;

      if (result is BatchManifestFetchSuccess) {
        final batch = result.batchManifest;
        _currentBatchManifest = batch;
        _currentManifest = batch.manifests.isNotEmpty ? batch.manifests.first : null;
        _discoveredRoom = room;

        final firstManifest = batch.manifests.isNotEmpty ? batch.manifests.first : null;
        final ext = firstManifest != null && firstManifest.fileName.contains('.')
            ? firstManifest.fileName.split('.').last.toLowerCase()
            : '';

        final fileInfo = FileInfo(
          id: firstManifest?.fileId ?? 'batch',
          name: batch.manifests.length > 1
              ? '${batch.totalFiles} files (${_formatBytes(batch.totalBytes)})'
              : (firstManifest?.fileName ?? 'File'),
          sizeBytes: batch.totalBytes,
          formattedSize: _formatBytes(batch.totalBytes),
          extension: ext,
          type: FileType.fromString(ext),
        );

        // Connect WebSocket early to announce presence and perform handshake
        final localServer = LocalServer();
        await localServer.start();

        final wsService = WebSocketService();
        await wsService.connect(
          hostIp: room.ip,
          port: room.port,
          localPeerId: localServer.localPeerId,
        );
        _activeWsService = wsService;

        final localIp = await NetworkUtils.getLocalIpAddress();
        wsService.sendReceiverJoined(
          peerId: localServer.localPeerId,
          deviceName: localServer.localDeviceName,
          platform: localServer.platform,
          ip: localIp,
        );

        final targetDir = await StoragePathService.getReceivedFilesDirectory();
        final availableSpace = await StorageDiagnosticsService().getAvailableStorageBytes(targetDir.path);
        final requiredBytes = batch.totalBytes + (20 * 1024 * 1024);

        if (availableSpace != null && availableSpace < requiredBytes) {
          wsService.sendReceiverFailed(
            peerId: localServer.localPeerId,
            error: 'INSUFFICIENT_STORAGE',
            availableBytes: availableSpace,
            requiredBytes: requiredBytes,
          );
          if (mounted && _connectionGeneration == currentGen) {
            setState(() {
              _isConnecting = false;
            });
            _showStorageErrorDialog(availableSpace, requiredBytes);
          }
          return;
        }

        wsService.sendReceiverReady(
          peerId: localServer.localPeerId,
          availableStorageBytes: availableSpace,
        );

        _wsSubscription?.cancel();
        _wsSubscription = wsService.messageStream.listen((msg) {
          final type = msg['type'] as String?;
          if (type == 'TRANSFER_START') {
            _hostTransferStarted = true;
            if (_userAcceptedTransfer && !_transferInitiated) {
              _startActualDownload();
            }
          }
        });

        if (mounted && _connectionGeneration == currentGen) {
          setState(() {
            _isConnecting = false;
            _manifestReceived = true;
            _connectedPin = pin;
            _incomingFile = fileInfo;
            _senderName = room.deviceName ?? 'Host (${room.ip})';
          });
        }
      } else if (result is BatchManifestFetchError) {
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to fetch manifest: ${result.message}'),
              backgroundColor: AppColors.primaryBlack,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted && _connectionGeneration == currentGen) {
        setState(() {
          _isConnecting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection error: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  void _joinRoomDirect(String ip, int port) async {
    final cleanIp = ip.trim();
    if (!NetworkUtils.isValidIpv4(cleanIp)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid IPv4 address format. Example: 192.168.43.1'),
          backgroundColor: AppColors.primaryBlack,
        ),
      );
      return;
    }
    if (port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid port number. Must be between 1 and 65535'),
          backgroundColor: AppColors.primaryBlack,
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    final currentGen = ++_connectionGeneration;
    setState(() {
      _isConnecting = true;
    });

    try {
      final httpClient = P2PHttpClient();

      // Health check before downloading manifests
      final health = await httpClient.checkHealth(cleanIp, port);
      if (!mounted || _connectionGeneration != currentGen) {
        httpClient.close();
        return;
      }
      if (health is! HealthCheckSuccess) {
        httpClient.close();
        if (mounted) {
          setState(() => _isConnecting = false);
          final errorMsg = health is HealthCheckUnreachable
              ? 'Could not connect to host at $cleanIp:$port. Ensure both devices are on the same Wi-Fi/Hotspot without client isolation.'
              : 'Host error: ${(health as HealthCheckFailure).message}';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: AppColors.primaryBlack,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      BatchManifestFetchResult result;
      try {
        result = await httpClient.downloadBatchManifest(cleanIp, port);
      } finally {
        httpClient.close();
      }

      if (!mounted || _connectionGeneration != currentGen) return;

      if (result is BatchManifestFetchSuccess) {
        final batch = result.batchManifest;
        final firstManifest = batch.manifests.isNotEmpty ? batch.manifests.first : null;
        final room = DiscoveredRoom(
          roomId: batch.batchId,
          ip: cleanIp,
          port: port,
          pin: 'DIRECT',
          deviceName: 'Direct Host ($cleanIp)',
        );
        _currentBatchManifest = batch;
        _currentManifest = firstManifest;
        _discoveredRoom = room;

        final ext = firstManifest != null && firstManifest.fileName.contains('.')
            ? firstManifest.fileName.split('.').last.toLowerCase()
            : '';

        final fileInfo = FileInfo(
          id: firstManifest?.fileId ?? 'batch',
          name: batch.manifests.length > 1
              ? '${batch.totalFiles} files (${_formatBytes(batch.totalBytes)})'
              : (firstManifest?.fileName ?? 'File'),
          sizeBytes: batch.totalBytes,
          formattedSize: _formatBytes(batch.totalBytes),
          extension: ext,
          type: FileType.fromString(ext),
        );

        final localServer = LocalServer();
        await localServer.start();

        final wsService = WebSocketService();
        await wsService.connect(
          hostIp: cleanIp,
          port: port,
          localPeerId: localServer.localPeerId,
        );
        _activeWsService = wsService;

        final localIp = await NetworkUtils.getLocalIpAddress();
        wsService.sendReceiverJoined(
          peerId: localServer.localPeerId,
          deviceName: localServer.localDeviceName,
          platform: localServer.platform,
          ip: localIp,
        );

        final targetDir = await StoragePathService.getReceivedFilesDirectory();
        final availableSpace = await StorageDiagnosticsService().getAvailableStorageBytes(targetDir.path);
        final requiredBytes = batch.totalBytes + (20 * 1024 * 1024);

        if (availableSpace != null && availableSpace < requiredBytes) {
          wsService.sendReceiverFailed(
            peerId: localServer.localPeerId,
            error: 'INSUFFICIENT_STORAGE',
            availableBytes: availableSpace,
            requiredBytes: requiredBytes,
          );
          if (mounted && _connectionGeneration == currentGen) {
            setState(() {
              _isConnecting = false;
            });
            _showStorageErrorDialog(availableSpace, requiredBytes);
          }
          return;
        }

        wsService.sendReceiverReady(
          peerId: localServer.localPeerId,
          availableStorageBytes: availableSpace,
        );

        _wsSubscription?.cancel();
        _wsSubscription = wsService.messageStream.listen((msg) {
          final type = msg['type'] as String?;
          if (type == 'TRANSFER_START') {
            _hostTransferStarted = true;
            if (_userAcceptedTransfer && !_transferInitiated) {
              _startActualDownload();
            }
          }
        });

        if (mounted && _connectionGeneration == currentGen) {
          setState(() {
            _isConnecting = false;
            _manifestReceived = true;
            _connectedPin = 'DIRECT';
            _incomingFile = fileInfo;
            _senderName = 'Direct Host ($cleanIp)';
          });
        }
      } else if (result is BatchManifestFetchError) {
        if (mounted) {
          setState(() => _isConnecting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to download manifest: ${result.message}'),
              backgroundColor: AppColors.primaryBlack,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted && _connectionGeneration == currentGen) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Direct connection error: $e'),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  void _showDirectConnectDialog() async {
    final localIp = await NetworkUtils.getLocalIpAddress();
    String defaultHost = '192.168.43.1';
    if (localIp != null && localIp.contains('.')) {
      final parts = localIp.split('.');
      if (parts.length == 4) {
        defaultHost = '${parts[0]}.${parts[1]}.${parts[2]}.1';
      }
    }

    if (!mounted) return;
    final ipController = TextEditingController(text: defaultHost);
    final portController = TextEditingController(text: '8080');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Hotspot Direct Connect',
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primaryBlack),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If UDP broadcast is blocked by hotspot client isolation, connect directly via the host IP address and HTTP port. Both devices must be on the same local network.',
              style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'Host IP Address',
                hintText: '192.168.43.1',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8080',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim()) ?? 8080;
              if (ip.isNotEmpty) {
                _joinRoomDirect(ip, port);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  void _resetToReady() {
    _connectionGeneration++;
    _wsSubscription?.cancel();
    _activeWsService?.disconnect();
    _activeWsService = null;
    _hostTransferStarted = false;
    _userAcceptedTransfer = false;
    _transferInitiated = false;
    setState(() {
      _manifestReceived = false;
      _isConnecting = false;
      _pinController.clear();
      _connectedPin = null;
      _currentBatchManifest = null;
      _currentManifest = null;
      _discoveredRoom = null;
      _incomingFile = const FileInfo(
        id: 'pending_file',
        name: 'Incoming File',
        sizeBytes: 0,
        formattedSize: '0 B',
        extension: '',
        type: FileType.Other,
      );
      _senderName = "Nearby Sender";
    });
  }

  void _showStorageErrorDialog(int availableBytes, int requiredBytes) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text('Insufficient Storage Space', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(
          'This incoming transfer requires ${_formatBytes(requiredBytes)} of free disk space, but only ${_formatBytes(availableBytes)} is available on your device. Please free up space and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resetToReady();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _startActualDownload() async {
    if (_transferInitiated || _discoveredRoom == null) return;
    _transferInitiated = true;

    final batch = _currentBatchManifest ??
        (_currentManifest != null
            ? BatchManifest.fromSingleManifest(_currentManifest!)
            : null);
    if (batch == null || batch.manifests.isEmpty) return;

    try {
      final destDir = await StoragePathService.getReceivedFilesDirectory();

      final localServer = LocalServer();
      await localServer.start();

      final wsService = _activeWsService ?? WebSocketService();
      if (!wsService.isConnected) {
        await wsService.connect(
          hostIp: _discoveredRoom!.ip,
          port: _discoveredRoom!.port,
          localPeerId: localServer.localPeerId,
        );
        _activeWsService = wsService;
      }

      final Map<String, Set<int>> hostChunksByFile = {};
      for (final m in batch.manifests) {
        hostChunksByFile[m.fileId] = Set.from(List.generate(m.chunkCount, (i) => i));
      }

      final hostPeer = PeerInfo(
        peerId: 'host_${_discoveredRoom!.ip}',
        deviceName: _senderName,
        platform: 'android',
        ip: _discoveredRoom!.ip,
        httpPort: _discoveredRoom!.port,
        webSocketPort: _discoveredRoom!.port,
        availableChunks: Set.from(
          List.generate(batch.manifests.first.chunkCount, (i) => i),
        ),
        availableChunksByFile: hostChunksByFile,
      );

      final List<BatchTransferItem> batchItems = [];
      final List<({Manifest manifest, File file})> serverBatch = [];

      for (final m in batch.manifests) {
        final destFile = await FilenameSanitizer.resolveUniqueFile(
          destDir,
          m.fileName,
        );
        serverBatch.add((manifest: m, file: destFile));

        final ext = m.fileName.contains('.')
            ? m.fileName.split('.').last.toLowerCase()
            : '';
        final info = FileInfo.fromMetadata(
          path: destFile.path,
          name: m.fileName,
          sizeBytes: m.fileSize,
          extension: ext,
        );

        batchItems.add(
          BatchTransferItem(
            fileId: m.fileId,
            fileInfo: info,
            manifest: m,
            destinationFile: destFile,
            totalBytes: m.fileSize,
          ),
        );
      }

      localServer.replaceBatchManifests(batch.batchId, serverBatch);

      final settings = AppSettings();
      final coordinator = BatchTransferCoordinator(
        batchId: batch.batchId,
        items: batchItems,
        swarmPeers: [hostPeer],
        localServer: localServer,
        webSocketService: wsService,
        localPeerId: localServer.localPeerId,
        coordinatorPeerId: hostPeer.peerId,
        concurrentWorkers: settings.maxParallelConnections,
        scheduler: settings.createConfiguredScheduler(),
      );

      await TransferSessionManager.instance.startReceiverBatchSession(
        coordinator: coordinator,
        batchManifest: batch,
      );

      coordinator.start();

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => TransferProgressScreen(
              batchCoordinator: coordinator,
              batchManifest: batch,
              fileInfo: batchItems.first.fileInfo,
              destinationFile: batchItems.first.destinationFile,
              manifest: batch.manifests.first,
              isHost: false,
              roomPin: _connectedPin,
            ),
          ),
        );
      }
    } catch (e) {
      _transferInitiated = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initiate transfer: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Receive File'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!_manifestReceived) ...[
                // Radar Pulse Animation
                SizedBox(
                  height: 140,
                  width: 140,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 140 * _pulseController.value,
                            height: 140 * _pulseController.value,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primaryBlack.withOpacity(
                                  (1.0 - _pulseController.value).clamp(0.0, 1.0),
                                ),
                                width: 2.0,
                              ),
                            ),
                          ),
                          Container(
                            width: 90 * _pulseController.value,
                            height: 90 * _pulseController.value,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primaryBlack.withOpacity(
                                  (1.0 - _pulseController.value * 0.8).clamp(0.0, 1.0),
                                ),
                                width: 2.0,
                              ),
                            ),
                          ),
                          Container(
                            width: 64,
                            height: 64,
                            decoration: const BoxDecoration(
                              color: AppColors.primaryBlack,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.arrow_downward_rounded,
                              color: AppColors.backgroundWhite,
                              size: 32,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.s16),
                const Text(
                  'Ready to Receive',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlack,
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                const Text(
                  'Enter 4-digit PIN generated by sender to join room and download file',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mediumGray,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s20),

                // PIN Entry Input Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.s20),
                  decoration: BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: AppShapes.cardBorderRadius,
                    border: Border.all(color: AppColors.borderGray),
                  ),
                  child: Column(
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.key_rounded, size: 20, color: AppColors.primaryBlack),
                          SizedBox(width: AppSpacing.s8),
                          Text(
                            'Enter Room PIN',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.s12),
                      TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8.0,
                          fontFamily: 'monospace',
                          color: AppColors.primaryBlack,
                        ),
                        decoration: InputDecoration(
                          hintText: '4821',
                          hintStyle: TextStyle(
                            fontSize: 20,
                            letterSpacing: 4.0,
                            color: AppColors.mediumGray.withOpacity(0.5),
                          ),
                          counterText: '',
                          filled: true,
                          fillColor: AppColors.backgroundWhite,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.borderGray),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.primaryBlack, width: 2),
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onChanged: (val) {
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: AppSpacing.s16),
                      PrimaryButton(
                        text: _isConnecting ? 'JOINING ROOM...' : 'JOIN ROOM',
                        icon: Icons.login_rounded,
                        onPressed: (_pinController.text.length == 4 && !_isConnecting)
                            ? _joinRoom
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.s12),
                      OutlinedButton.icon(
                        icon: const Icon(
                          Icons.wifi_tethering_rounded,
                          size: 18,
                          color: AppColors.primaryBlack,
                        ),
                        label: const Text(
                          'HOTSPOT DIRECT CONNECT',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 44),
                          side: const BorderSide(color: AppColors.borderGray),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isConnecting ? null : _showDirectConnectDialog,
                      ),
                    ],
                  ),
                ),
                if (_isConnecting) ...[
                  const SizedBox(height: AppSpacing.s16),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundWhite,
                      borderRadius: AppShapes.cardBorderRadius,
                      border: Border.all(color: AppColors.borderGray),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                        SizedBox(width: AppSpacing.s12),
                        Text(
                          'Simulating room discovery & fetching manifest...',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ] else ...[
                // Connected / Manifest Received State
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.s16),
                  decoration: BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: AppShapes.cardBorderRadius,
                    border: Border.all(color: AppColors.borderGray),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: AppColors.primaryBlack,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.phone_android_rounded,
                          color: AppColors.backgroundWhite,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$_senderName wants to send you a file',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Connected to Room PIN: $_connectedPin',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.mediumGray,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s20),

                // Incoming File(s) Details Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.s20),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: AppShapes.cardBorderRadius,
                    border: Border.all(color: AppColors.primaryBlack, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: BorderRadius.circular(14.0),
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: Icon(
                          _currentBatchManifest != null && _currentBatchManifest!.manifests.length > 1
                              ? Icons.folder_copy_rounded
                              : Icons.insert_drive_file_rounded,
                          color: AppColors.primaryBlack,
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s12),
                      Text(
                        _incomingFile.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlack,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      Text(
                        _currentBatchManifest != null && _currentBatchManifest!.manifests.length > 1
                            ? '${_currentBatchManifest!.totalFiles} files • ${_formatBytes(_currentBatchManifest!.totalBytes)}'
                            : '${_incomingFile.formattedSize} • ${_incomingFile.extension.toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.mediumGray,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (_currentBatchManifest != null && _currentBatchManifest!.manifests.length > 1) ...[
                        const SizedBox(height: 16),
                        const Divider(height: 1, color: AppColors.borderGray),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _currentBatchManifest!.manifests.length,
                            itemBuilder: (context, idx) {
                              final m = _currentBatchManifest!.manifests[idx];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  children: [
                                    const Icon(Icons.insert_drive_file_outlined, size: 16, color: AppColors.darkGray),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        m.fileName,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatBytes(m.fileSize),
                                      style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s20),

                // File Details
                const SectionHeader(title: 'Transfer Details'),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundWhite,
                    borderRadius: AppShapes.cardBorderRadius,
                    border: Border.all(color: AppColors.borderGray),
                  ),
                  child: Column(
                    children: [
                      _buildMetadataRow(
                        label: 'Total Files',
                        value: '${_currentBatchManifest?.totalFiles ?? 1}',
                        icon: Icons.numbers_rounded,
                      ),
                      const Divider(height: 1, color: AppColors.borderGray),
                      _buildMetadataRow(
                        label: 'Total Size',
                        value: _formatBytes(_currentBatchManifest?.totalBytes ?? _incomingFile.sizeBytes),
                        icon: Icons.data_usage_rounded,
                      ),
                      const Divider(height: 1, color: AppColors.borderGray),
                      _buildMetadataRow(
                        label: 'Sender',
                        value: _senderName,
                        icon: Icons.person_outline_rounded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s24),

                // ACCEPT / DECLINE Buttons
                Column(
                  children: [
                    if (_userAcceptedTransfer && !_hostTransferStarted) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        decoration: BoxDecoration(
                          color: AppColors.lightGray,
                          borderRadius: AppShapes.cardBorderRadius,
                          border: Border.all(color: AppColors.borderGray),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            SizedBox(width: AppSpacing.s12),
                            Text(
                              'Ready! Waiting for sender to start transfer...',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      PrimaryButton(
                        text: _currentBatchManifest != null && _currentBatchManifest!.manifests.length > 1
                            ? 'ACCEPT BATCH (${_currentBatchManifest!.totalFiles} FILES)'
                            : 'ACCEPT',
                        icon: Icons.check_circle_outline_rounded,
                        onPressed: () async {
                          setState(() {
                            _userAcceptedTransfer = true;
                          });
                          if (_hostTransferStarted) {
                            await _startActualDownload();
                          }
                        },
                      ),
                    ],
                    const SizedBox(height: AppSpacing.s12),
                    SecondaryButton(
                      text: 'DECLINE',
                      icon: Icons.close_rounded,
                      onPressed: _resetToReady,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataRow({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.darkGray),
          const SizedBox(width: AppSpacing.s12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.mediumGray,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
        ],
      ),
    );
  }
}
