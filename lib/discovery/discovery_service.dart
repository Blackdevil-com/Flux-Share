import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/peer.dart';
import '../network/multicast_lock_service.dart';
import '../network/network_utils.dart';
import 'discovery_packet.dart';

class DiscoveredRoom {
  final String roomId;
  final String ip;
  final int port;
  final String pin;
  final String? deviceName;

  DiscoveredRoom({
    required this.roomId,
    required this.ip,
    required this.port,
    required this.pin,
    this.deviceName,
  });
}

sealed class RoomHostStartResult {}

class RoomHostStartSuccess extends RoomHostStartResult {
  final int discoveryPort;
  final String localIp;
  final int serverPort;
  RoomHostStartSuccess({
    required this.discoveryPort,
    required this.localIp,
    required this.serverPort,
  });
}

class RoomHostStartFailure extends RoomHostStartResult {
  final String reason;
  final Object? error;
  RoomHostStartFailure({required this.reason, this.error});
}

sealed class DiscoverRoomResult {}

class DiscoverRoomSuccess extends DiscoverRoomResult {
  final DiscoveredRoom room;
  DiscoverRoomSuccess(this.room);
}

class DiscoverRoomTimeout extends DiscoverRoomResult {
  final String pin;
  final List<String> targetsAttempted;
  DiscoverRoomTimeout({required this.pin, required this.targetsAttempted});
}

class DiscoverRoomFailure extends DiscoverRoomResult {
  final String reason;
  final Object? error;
  DiscoverRoomFailure({required this.reason, this.error});
}

/// UDP Broadcast & Unicast Discovery Service on local Wi-Fi / Hotspot networks.
///
/// Implemented as a singleton to guarantee a single unified UDP listening socket on
/// port 8888, eliminating port binding collisions (EADDRINUSE) between peer presence
/// and room host listeners, and reliably multiplexing incoming packets.
class DiscoveryService {
  static const int defaultDiscoveryPort = 8888;

  static final DiscoveryService _instance = DiscoveryService._internal();
  factory DiscoveryService() => _instance;
  DiscoveryService._internal();

  RawDatagramSocket? _serverSocket;
  int? _boundDiscoveryPort;

  // Active peer presence configuration
  ({String peerId, String deviceName, String platform, int serverPort})? _activePresence;

  // Active room host configuration
  ({String pin, String roomId, int serverPort, String deviceName})? _activeRoom;

  bool get isRoomHostingActive => _activeRoom != null;
  bool get isPresenceActive => _activePresence != null;
  String? get activeRoomPin => _activeRoom?.pin;
  int? get boundDiscoveryPort => _boundDiscoveryPort;

  @visibleForTesting
  static Future<RawDatagramSocket> Function(
    dynamic host,
    int port, {
    bool reuseAddress,
    bool reusePort,
    int ttl,
  })? customSocketBinder;

  @visibleForTesting
  static void resetForTesting() {
    _instance._activePresence = null;
    _instance._activeRoom = null;
    _instance._closeServerSocket();
    customSocketBinder = null;
  }

  /// Ensures the unified UDP server socket is bound and listening on [discoveryPort].
  Future<void> _ensureServerSocket(int discoveryPort) async {
    if (_serverSocket != null && _boundDiscoveryPort == discoveryPort) {
      return;
    }

    if (_serverSocket != null) {
      _closeServerSocket();
    }

    await MulticastLockService.acquire();
    try {
      final RawDatagramSocket socket;
      if (customSocketBinder != null) {
        socket = await customSocketBinder!(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      } else {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      }
      socket.broadcastEnabled = true;
      _serverSocket = socket;
      _boundDiscoveryPort = discoveryPort;

      final localIp = await NetworkUtils.getLocalIpAddress() ?? '0.0.0.0';
      debugPrint('[FluxShare-Network] [DiscoveryHost] Listener active: bound to 0.0.0.0:$discoveryPort (Local IP: $localIp)');

      socket.listen(
        _handleServerDatagramEvent,
        onError: (e) {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Socket error on port $discoveryPort: $e');
        },
        onDone: () {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Socket closed on port $discoveryPort');
        },
      );
    } catch (e) {
      await MulticastLockService.release();
      rethrow;
    }
  }

  void _closeServerSocket() {
    if (_serverSocket != null) {
      try {
        _serverSocket?.close();
      } catch (_) {}
      _serverSocket = null;
      _boundDiscoveryPort = null;
      unawaited(MulticastLockService.release());
    }
  }

  /// Unified packet dispatcher for incoming UDP datagrams on port 8888.
  void _handleServerDatagramEvent(RawSocketEvent event) async {
    if (event != RawSocketEvent.read) return;
    final socket = _serverSocket;
    if (socket == null) return;

    final datagram = socket.receive();
    if (datagram == null) return;

    final text = utf8.decode(datagram.data).trim();
    final packet = DiscoveryPacket.tryDecode(text);
    if (packet == null) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Malformed packet received from ${datagram.address.address}:${datagram.port}');
      return;
    }

    debugPrint('[FluxShare-Network] [DiscoveryHost] Datagram received: action=${packet.action} from ${datagram.address.address}:${datagram.port}');

    if (packet.action == 'PEER_DISCOVERY') {
      final presence = _activePresence;
      if (presence != null) {
        final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
        final reply = DiscoveryPacket(
          action: 'PEER_ANNOUNCE',
          peerId: presence.peerId,
          deviceName: presence.deviceName,
          platform: presence.platform,
          ip: localIp,
          port: presence.serverPort,
        );
        final bytes = utf8.encode(reply.encode());
        try {
          socket.send(bytes, datagram.address, datagram.port);
        } catch (e) {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Failed to send PEER_ANNOUNCE to ${datagram.address.address}: $e');
        }
      }
    } else if (packet.action == 'DISCOVER_ROOM') {
      final room = _activeRoom;
      if (room != null) {
        if (packet.pin == room.pin) {
          final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
          debugPrint('[FluxShare-Network] [DiscoveryHost] Request PIN match: true (PIN: ${room.pin}) from ${datagram.address.address}:${datagram.port}. Sending ROOM_FOUND (ip=$localIp, port=${room.serverPort})');

          final reply = DiscoveryPacket(
            action: 'ROOM_FOUND',
            pin: room.pin,
            roomId: room.roomId,
            ip: localIp,
            port: room.serverPort,
            deviceName: room.deviceName,
          );

          final bytes = utf8.encode(reply.encode());
          try {
            socket.send(bytes, datagram.address, datagram.port);
            // Send duplicate packet immediately to safeguard against lossy Wi-Fi UDP drops
            socket.send(bytes, datagram.address, datagram.port);
            debugPrint('[FluxShare-Network] [DiscoveryHost] Sent ROOM_FOUND reply to ${datagram.address.address}:${datagram.port}');
          } catch (e) {
            debugPrint('[FluxShare-Network] [DiscoveryHost] Failed to send ROOM_FOUND reply to ${datagram.address.address}: $e');
          }
        } else {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Request PIN match: false (received ${packet.pin?.length} chars != expected ${room.pin}) from ${datagram.address.address}:${datagram.port}');
        }
      } else {
        debugPrint('[FluxShare-Network] [DiscoveryHost] Received DISCOVER_ROOM from ${datagram.address.address}:${datagram.port}, but no active room hosted on this device');
      }
    }
  }

  /// Starts listening for UDP broadcast join requests for a specific room PIN.
  /// Returns a typed result indicating success or explicit bind failure.
  Future<RoomHostStartResult> startRoomHost({
    required String pin,
    required String roomId,
    required int serverPort,
    required String deviceName,
    int discoveryPort = defaultDiscoveryPort,
  }) async {
    _activeRoom = (
      pin: pin,
      roomId: roomId,
      serverPort: serverPort,
      deviceName: deviceName,
    );

    debugPrint('[FluxShare-Network] [DiscoveryHost] Starting room host for PIN=$pin, roomId=$roomId, serverPort=$serverPort on UDP port $discoveryPort');

    try {
      await _ensureServerSocket(discoveryPort);
      final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
      return RoomHostStartSuccess(
        discoveryPort: discoveryPort,
        localIp: localIp,
        serverPort: serverPort,
      );
    } catch (e) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Bind error on port $discoveryPort: $e');
      _activeRoom = null;
      return RoomHostStartFailure(
        reason: 'UDP_BIND_FAILED: $e',
        error: e,
      );
    }
  }

  /// Stops room hosting. If peer presence is not active, releases the socket.
  void stopRoomHost() {
    if (_activeRoom != null) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Stopping room host listener (PIN: ${_activeRoom?.pin})');
      _activeRoom = null;
      if (_activePresence == null) {
        _closeServerSocket();
      }
    }
  }

  /// Starts background listener to respond to nearby peer discovery scans.
  Future<void> startPeerPresenceListener({
    required String peerId,
    required String deviceName,
    required String platform,
    required int serverPort,
    int discoveryPort = defaultDiscoveryPort,
  }) async {
    _activePresence = (
      peerId: peerId,
      deviceName: deviceName,
      platform: platform,
      serverPort: serverPort,
    );

    try {
      await _ensureServerSocket(discoveryPort);
    } catch (e) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Peer presence bind error on port $discoveryPort: $e');
    }
  }

  /// Stops peer presence listening. If room host is not active, releases the socket.
  void stopPeerPresenceListener() {
    if (_activePresence != null) {
      _activePresence = null;
      if (_activeRoom == null) {
        _closeServerSocket();
      }
    }
  }

  /// Broadcasts UDP discovery packets to locate nearby active peers on the LAN/Hotspot.
  Future<List<PeerInfo>> scanNearbyPeers({
    int discoveryPort = defaultDiscoveryPort,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final discovered = <String, PeerInfo>{};
    RawDatagramSocket? socket;
    Timer? timer;
    await MulticastLockService.acquire();

    try {
      if (customSocketBinder != null) {
        socket = await customSocketBinder!(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      } else {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      }
      socket.broadcastEnabled = true;

      final packet = DiscoveryPacket(action: 'PEER_DISCOVERY');
      final bytes = utf8.encode(packet.encode());

      final targets = await NetworkUtils.getDiscoveryTargets();

      for (final target in targets) {
        try {
          socket.send(bytes, target, discoveryPort);
        } catch (_) {}
      }

      timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        for (final target in targets) {
          try {
            socket?.send(bytes, target, discoveryPort);
          } catch (_) {}
        }
      });

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram == null) return;

          final text = utf8.decode(datagram.data).trim();
          final reply = DiscoveryPacket.tryDecode(text);

          if (reply != null && reply.action == 'PEER_ANNOUNCE' && reply.peerId != null) {
            final rawIp = reply.ip;
            final packetIp = datagram.address.address;
            final resolvedIp = (rawIp != null &&
                    rawIp.isNotEmpty &&
                    !rawIp.startsWith('127.') &&
                    rawIp != '0.0.0.0')
                ? rawIp
                : packetIp;

            discovered[reply.peerId!] = PeerInfo(
              peerId: reply.peerId!,
              deviceName: reply.deviceName ?? 'FluxShare Device',
              platform: reply.platform ?? 'android',
              ip: resolvedIp,
              httpPort: reply.port ?? 8080,
              webSocketPort: reply.port ?? 8080,
            );
          }
        }
      });

      await Future.delayed(timeout);
      timer.cancel();
      socket.close();
      return discovered.values.toList();
    } catch (_) {
      timer?.cancel();
      socket?.close();
      return discovered.values.toList();
    } finally {
      await MulticastLockService.release();
    }
  }

  /// Detailed room discovery returning typed DiscoverRoomResult with distinct failure reasons.
  Future<DiscoverRoomResult> discoverRoomResult({
    required String pin,
    int discoveryPort = defaultDiscoveryPort,
    Duration timeout = const Duration(milliseconds: 4500),
  }) async {
    RawDatagramSocket? clientSocket;
    Timer? timer;
    Timer? unicastWaveTimer;
    final completer = Completer<DiscoverRoomResult>();
    await MulticastLockService.acquire();

    final localIp = await NetworkUtils.getLocalIpAddress();
    final targets = await NetworkUtils.getDiscoveryTargets(localIpOverride: localIp);
    final targetAddresses = targets.map((t) => t.address).toList();

    debugPrint('[FluxShare-Network] [Receiver] Local IP: $localIp, Protocol: UDP, Port: $discoveryPort');
    debugPrint('[FluxShare-Network] [Receiver] Attempting targets: $targetAddresses for PIN=$pin');

    try {
      if (customSocketBinder != null) {
        clientSocket = await customSocketBinder!(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      } else {
        clientSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
      }
      clientSocket.broadcastEnabled = true;

      final packet = DiscoveryPacket(action: 'DISCOVER_ROOM', pin: pin);
      final bytes = utf8.encode(packet.encode());

      void sendPacket(InternetAddress target) {
        try {
          final sent = clientSocket?.send(bytes, target, discoveryPort) ?? 0;
          if (sent == 0) {
            debugPrint('[FluxShare-Network] [Receiver] Warning: 0 bytes sent to ${target.address}:$discoveryPort');
          }
        } catch (e) {
          debugPrint('[FluxShare-Network] [Receiver] Error sending to ${target.address}: $e');
        }
      }

      // 1. Initial send across all primary targets (broadcast, gateway, known peers)
      for (final target in targets) {
        sendPacket(target);
      }

      // 2. Periodic broadcast timer (every 300 ms)
      timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        for (final target in targets) {
          sendPacket(target);
        }
      });

      // 3. Fallback unicast wave across local /24 subnet after 350ms.
      // If the Wi-Fi router filters/blocks UDP broadcast (multicast/broadcast suppression),
      // sending unicast datagrams directly to candidate subnet IPs reaches the host.
      if (localIp != null && localIp.contains('.')) {
        final parts = localIp.split('.');
        if (parts.length == 4) {
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          unicastWaveTimer = Timer(const Duration(milliseconds: 350), () {
            if (completer.isCompleted) return;
            debugPrint('[FluxShare-Network] [Receiver] Dispatching fallback unicast wave across subnet $prefix.0/24');
            for (int i = 1; i <= 254; i++) {
              final candidateIp = '$prefix.$i';
              if (candidateIp == localIp) continue;
              sendPacket(InternetAddress(candidateIp));
            }
          });
        }
      }

      // Socket listen
      clientSocket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = clientSocket?.receive();
            if (datagram == null) return;

            final text = utf8.decode(datagram.data).trim();
            final reply = DiscoveryPacket.tryDecode(text);

            final isTypeMatch = reply?.action == 'ROOM_FOUND';
            final isPinMatch = reply?.pin == pin;
            debugPrint('[FluxShare-Network] [Receiver] Response received from ${datagram.address.address}:${datagram.port}, type=${reply?.action}, pinMatch=$isPinMatch');

            if (reply != null &&
                isTypeMatch &&
                isPinMatch &&
                reply.port != null) {
              final rawIp = reply.ip;
              final packetIp = datagram.address.address;

              String resolvedIp = packetIp;
              if (rawIp != null &&
                  rawIp.isNotEmpty &&
                  !rawIp.startsWith('127.') &&
                  rawIp != '0.0.0.0') {
                if (localIp != null && NetworkUtils.isSameSubnet(rawIp, localIp)) {
                  resolvedIp = rawIp;
                } else if (packetIp.startsWith('127.') || packetIp == '0.0.0.0') {
                  resolvedIp = rawIp;
                }
              }

              debugPrint('[FluxShare-Network] [Receiver] ROOM_FOUND verified: source=${datagram.address.address}, hostIp=$resolvedIp, port=${reply.port}');

              timer?.cancel();
              unicastWaveTimer?.cancel();
              if (!completer.isCompleted) {
                completer.complete(
                  DiscoverRoomSuccess(
                    DiscoveredRoom(
                      roomId: reply.roomId ?? '',
                      ip: resolvedIp,
                      port: reply.port!,
                      pin: pin,
                      deviceName: reply.deviceName,
                    ),
                  ),
                );
              }
            } else if (reply != null && isTypeMatch && !isPinMatch) {
              debugPrint('[FluxShare-Network] [Receiver] Ignored ROOM_FOUND with mismatched PIN ${reply.pin} (expected $pin)');
            }
          }
        },
        onError: (e) {
          debugPrint('[FluxShare-Network] [Receiver] Discovery client socket error: $e');
        },
      );

      // Handle bounded timeout
      final timerRef = timer;
      final waveTimerRef = unicastWaveTimer;
      Future.delayed(timeout, () {
        timerRef.cancel();
        waveTimerRef?.cancel();
        if (!completer.isCompleted) {
          debugPrint('[FluxShare-Network] [Receiver] Discovery timed out after ${timeout.inMilliseconds}ms for PIN=$pin (targets attempted: $targetAddresses)');
          completer.complete(
            DiscoverRoomTimeout(
              pin: pin,
              targetsAttempted: targetAddresses,
            ),
          );
        }
      });

      final result = await completer.future;
      timer.cancel();
      unicastWaveTimer?.cancel();
      clientSocket.close();
      return result;
    } catch (e) {
      debugPrint('[FluxShare-Network] [Receiver] Discovery exception: $e');
      timer?.cancel();
      unicastWaveTimer?.cancel();
      clientSocket?.close();
      return DiscoverRoomFailure(
        reason: 'DISCOVERY_SOCKET_FAILED: $e',
        error: e,
      );
    } finally {
      await MulticastLockService.release();
    }
  }

  /// Broadcasts UDP packets to find a room with a specific PIN within a timeout.
  /// Preserves backward compatibility with legacy signature.
  Future<DiscoveredRoom?> discoverRoomByPin({
    required String pin,
    int discoveryPort = defaultDiscoveryPort,
    Duration timeout = const Duration(milliseconds: 3800),
  }) async {
    final result = await discoverRoomResult(
      pin: pin,
      discoveryPort: discoveryPort,
      timeout: timeout,
    );
    if (result is DiscoverRoomSuccess) {
      return result.room;
    }
    return null;
  }
}
