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
class DiscoveryService {
  static const int defaultDiscoveryPort = 8888;
  RawDatagramSocket? _hostSocket;
  RawDatagramSocket? _presenceSocket;

  @visibleForTesting
  static Future<RawDatagramSocket> Function(
    dynamic host,
    int port, {
    bool reuseAddress,
    bool reusePort,
    int ttl,
  })? customSocketBinder;

  /// Starts listening for UDP broadcast join requests for a specific room PIN.
  /// Returns a typed result indicating success or explicit bind failure.
  Future<RoomHostStartResult> startRoomHost({
    required String pin,
    required String roomId,
    required int serverPort,
    required String deviceName,
    int discoveryPort = defaultDiscoveryPort,
  }) async {
    stopRoomHost();
    await MulticastLockService.acquire();

    debugPrint('[FluxShare-Network] [DiscoveryHost] Starting room host for PIN=$pin, roomId=$roomId, serverPort=$serverPort on UDP port $discoveryPort');

    try {
      final RawDatagramSocket socket;
      if (customSocketBinder != null) {
        socket = await customSocketBinder!(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
      } else {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
      }
      socket.broadcastEnabled = true;
      _hostSocket = socket;

      final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
      debugPrint('[FluxShare-Network] [DiscoveryHost] Listener successfully bound to UDP port $discoveryPort. Local IP: $localIp');

      socket.listen(
        (RawSocketEvent event) async {
          if (event == RawSocketEvent.read) {
            final datagram = socket.receive();
            if (datagram == null) return;

            final text = utf8.decode(datagram.data).trim();
            final packet = DiscoveryPacket.tryDecode(text);

            if (packet == null) {
              debugPrint('[FluxShare-Network] [DiscoveryHost] Malformed packet received from ${datagram.address.address}:${datagram.port}');
              return;
            }

            if (packet.action == 'DISCOVER_ROOM') {
              if (packet.pin == pin) {
                final currentLocalIp = await NetworkUtils.getLocalIpAddress() ?? localIp;
                debugPrint('[FluxShare-Network] [DiscoveryHost] PIN match ($pin) from ${datagram.address.address}:${datagram.port}. Sending ROOM_FOUND (ip=$currentLocalIp, port=$serverPort)');

                final reply = DiscoveryPacket(
                  action: 'ROOM_FOUND',
                  pin: pin,
                  roomId: roomId,
                  ip: currentLocalIp,
                  port: serverPort,
                  deviceName: deviceName,
                );

                final bytes = utf8.encode(reply.encode());
                try {
                  socket.send(bytes, datagram.address, datagram.port);
                } catch (e) {
                  debugPrint('[FluxShare-Network] [DiscoveryHost] Failed to send ROOM_FOUND reply to ${datagram.address.address}: $e');
                }
              } else {
                debugPrint('[FluxShare-Network] [DiscoveryHost] PIN mismatch: received ${packet.pin?.length} chars != expected $pin from ${datagram.address.address}:${datagram.port}');
              }
            }
          }
        },
        onError: (e) {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Socket error: $e');
        },
        onDone: () {
          debugPrint('[FluxShare-Network] [DiscoveryHost] Socket closed');
        },
      );

      return RoomHostStartSuccess(
        discoveryPort: discoveryPort,
        localIp: localIp,
        serverPort: serverPort,
      );
    } catch (e) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Failed to bind UDP discovery port $discoveryPort: $e');
      await MulticastLockService.release();
      return RoomHostStartFailure(
        reason: 'UDP_BIND_FAILED: $e',
        error: e,
      );
    }
  }

  void stopRoomHost() {
    if (_hostSocket != null) {
      debugPrint('[FluxShare-Network] [DiscoveryHost] Stopping room host listener');
      _hostSocket?.close();
      _hostSocket = null;
      MulticastLockService.release();
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
    stopPeerPresenceListener();
    await MulticastLockService.acquire();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _presenceSocket = socket;

      socket.listen((RawSocketEvent event) async {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram == null) return;

          final text = utf8.decode(datagram.data).trim();
          final packet = DiscoveryPacket.tryDecode(text);

          if (packet != null && packet.action == 'PEER_DISCOVERY') {
            final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
            final reply = DiscoveryPacket(
              action: 'PEER_ANNOUNCE',
              peerId: peerId,
              deviceName: deviceName,
              platform: platform,
              ip: localIp,
              port: serverPort,
            );
            final bytes = utf8.encode(reply.encode());
            socket.send(bytes, datagram.address, datagram.port);
          }
        }
      });
    } catch (e) {
      debugPrint('[FluxShare-Network] [PeerPresence] Bind failed: $e');
    }
  }

  void stopPeerPresenceListener() {
    if (_presenceSocket != null) {
      _presenceSocket?.close();
      _presenceSocket = null;
      MulticastLockService.release();
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
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
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
    final completer = Completer<DiscoverRoomResult>();
    await MulticastLockService.acquire();

    final localIp = await NetworkUtils.getLocalIpAddress();
    final targets = await NetworkUtils.getDiscoveryTargets(localIpOverride: localIp);
    final targetAddresses = targets.map((t) => t.address).toList();

    debugPrint('[FluxShare-Network] [Receiver] Discovering room for PIN=$pin across targets: $targetAddresses');

    try {
      if (customSocketBinder != null) {
        clientSocket = await customSocketBinder!(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
        );
      } else {
        clientSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
        );
      }
      clientSocket.broadcastEnabled = true;

      final packet = DiscoveryPacket(action: 'DISCOVER_ROOM', pin: pin);
      final bytes = utf8.encode(packet.encode());

      // Initial send across all targets
      for (final target in targets) {
        try {
          clientSocket.send(bytes, target, discoveryPort);
        } catch (e) {
          debugPrint('[FluxShare-Network] [Receiver] Error sending to ${target.address}: $e');
        }
      }

      // Periodic broadcast timer (every 300 ms)
      timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        for (final target in targets) {
          try {
            clientSocket?.send(bytes, target, discoveryPort);
          } catch (_) {}
        }
      });

      // Socket listen
      clientSocket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = clientSocket?.receive();
            if (datagram == null) return;

            final text = utf8.decode(datagram.data).trim();
            final reply = DiscoveryPacket.tryDecode(text);

            if (reply != null &&
                reply.action == 'ROOM_FOUND' &&
                reply.pin == pin &&
                reply.port != null) {
              final rawIp = reply.ip;
              final packetIp = datagram.address.address;

              // Careful IP resolution:
              // Prefer advertised IP if valid private IP and matches local subnet,
              // otherwise fallback to packet physical source IP.
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

              debugPrint('[FluxShare-Network] [Receiver] ROOM_FOUND received! Source=${datagram.address.address}, advertised=${reply.ip}:${reply.port}, resolved=$resolvedIp');

              timer?.cancel();
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
            } else if (reply != null && reply.action == 'ROOM_FOUND') {
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
      Future.delayed(timeout, () {
        timerRef.cancel();
        if (!completer.isCompleted) {
          debugPrint('[FluxShare-Network] [Receiver] Discovery timed out after ${timeout.inMilliseconds}ms for PIN=$pin');
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
      clientSocket.close();
      return result;
    } catch (e) {
      debugPrint('[FluxShare-Network] [Receiver] Discovery exception: $e');
      timer?.cancel();
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
