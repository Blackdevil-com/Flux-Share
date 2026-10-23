import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/peer.dart';
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

/// UDP Broadcast Discovery Service on local Wi-Fi network.
class DiscoveryService {
  static const int defaultDiscoveryPort = 8888;
  RawDatagramSocket? _hostSocket;
  RawDatagramSocket? _presenceSocket;

  /// Starts listening for UDP broadcast join requests for a specific room PIN.
  Future<void> startRoomHost({
    required String pin,
    required String roomId,
    required int serverPort,
    required String deviceName,
    int discoveryPort = defaultDiscoveryPort,
  }) async {
    stopRoomHost();

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _hostSocket = socket;

      socket.listen((RawSocketEvent event) async {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram == null) return;

          final text = utf8.decode(datagram.data).trim();
          final packet = DiscoveryPacket.tryDecode(text);

          if (packet != null && packet.action == 'DISCOVER_ROOM' && packet.pin == pin) {
            final localIp = await NetworkUtils.getLocalIpAddress() ?? '';
            final reply = DiscoveryPacket(
              action: 'ROOM_FOUND',
              pin: pin,
              roomId: roomId,
              ip: localIp,
              port: serverPort,
              deviceName: deviceName,
            );

            final bytes = utf8.encode(reply.encode());
            socket.send(bytes, datagram.address, datagram.port);
          }
        }
      });
    } catch (_) {}
  }

  void stopRoomHost() {
    _hostSocket?.close();
    _hostSocket = null;
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
    } catch (_) {}
  }

  void stopPeerPresenceListener() {
    _presenceSocket?.close();
    _presenceSocket = null;
  }

  /// Broadcasts UDP discovery packets to locate nearby active peers on the LAN.
  Future<List<PeerInfo>> scanNearbyPeers({
    int discoveryPort = defaultDiscoveryPort,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final discovered = <String, PeerInfo>{};
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      final packet = DiscoveryPacket(action: 'PEER_DISCOVERY');
      final bytes = utf8.encode(packet.encode());

      final broadcastIp = await NetworkUtils.getBroadcastAddress();
      final targets = <InternetAddress>{
        InternetAddress(broadcastIp),
        InternetAddress('255.255.255.255'),
      };

      for (final target in targets) {
        try {
          socket.send(bytes, target, discoveryPort);
        } catch (_) {}
      }

      final timer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        for (final target in targets) {
          try {
            socket?.send(bytes, target, discoveryPort);
          } catch (_) {}
        }
      });

      final completer = Completer<void>();
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
      socket?.close();
      return discovered.values.toList();
    }
  }

  /// Broadcasts UDP packets to find a room with a specific PIN within a timeout.
  Future<DiscoveredRoom?> discoverRoomByPin({
    required String pin,
    int discoveryPort = defaultDiscoveryPort,
    Duration timeout = const Duration(milliseconds: 3500),
  }) async {
    RawDatagramSocket? clientSocket;
    final completer = Completer<DiscoveredRoom?>();

    try {
      clientSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      clientSocket.broadcastEnabled = true;

      final packet = DiscoveryPacket(action: 'DISCOVER_ROOM', pin: pin);
      final bytes = utf8.encode(packet.encode());

      final broadcastIp = await NetworkUtils.getBroadcastAddress();
      final targets = <InternetAddress>{
        InternetAddress(broadcastIp),
        InternetAddress('255.255.255.255'),
      };

      // Periodic broadcast timer
      final timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
        for (final target in targets) {
          try {
            clientSocket?.send(bytes, target, discoveryPort);
          } catch (_) {}
        }
      });

      // Socket listen
      clientSocket.listen((RawSocketEvent event) {
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
            final resolvedIp = (rawIp != null &&
                    rawIp.isNotEmpty &&
                    !rawIp.startsWith('127.') &&
                    rawIp != '0.0.0.0')
                ? rawIp
                : packetIp;

            timer.cancel();
            if (!completer.isCompleted) {
              completer.complete(
                DiscoveredRoom(
                  roomId: reply.roomId ?? '',
                  ip: resolvedIp,
                  port: reply.port!,
                  pin: pin,
                  deviceName: reply.deviceName,
                ),
              );
            }
          }
        }
      });

      Future.delayed(timeout, () {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final result = await completer.future;
      clientSocket.close();
      return result;
    } catch (_) {
      clientSocket?.close();
      return null;
    }
  }
}
