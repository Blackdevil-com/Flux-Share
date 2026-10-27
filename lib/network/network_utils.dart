import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../peer/peer_manager.dart';

/// Network utilities for interface detection, IP resolution, and reachability.
class NetworkUtils {
  @visibleForTesting
  static String? customLocalIp;

  @visibleForTesting
  static List<NetworkInterface>? customInterfaces;

  /// Discovers local non-loopback IPv4 address on active LAN interfaces.
  /// Prioritizes Wi-Fi Hotspot (ap, softap, swlan), Wi-Fi client (wlan, wl, p2p),
  /// and Ethernet (eth, en), filtering out virtual/VPN/cellular.
  static Future<String?> getLocalIpAddress() async {
    if (customLocalIp != null) return customLocalIp;

    final candidates = await getAllLocalIpAddresses();
    if (candidates.isNotEmpty) {
      final selected = candidates.first;
      debugPrint('[FluxShare-Network] [HostIP] Selected primary local IP: $selected');
      return selected;
    }

    debugPrint('[FluxShare-Network] [HostIP] Warning: No eligible local IPv4 address discovered');
    return null;
  }

  /// Returns all eligible local IPv4 addresses sorted by priority score.
  static Future<List<String>> getAllLocalIpAddresses() async {
    if (customLocalIp != null) return [customLocalIp!];

    try {
      final interfaces = customInterfaces ??
          await NetworkInterface.list(
            includeLoopback: false,
            type: InternetAddressType.IPv4,
          ).timeout(const Duration(seconds: 2), onTimeout: () => []);

      final scored = <({String ip, String ifaceName, int score})>[];

      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (_isExcludedInterface(name)) {
          continue;
        }

        final ifaceBaseScore = _getInterfaceBaseScore(name);

        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (addr.isLoopback ||
              ip.startsWith('127.') ||
              ip.startsWith('169.254.') ||
              ip == '0.0.0.0' ||
              ip == '255.255.255.255' ||
              !ip.contains('.')) {
            continue;
          }

          int ipScore = ifaceBaseScore;
          if (isPrivateIp(ip)) {
            // Private LAN ranges
            if (ip.startsWith('192.168.43.')) {
              // Standard Android Hotspot subnet
              ipScore += 45;
            } else if (ip.startsWith('192.168.')) {
              ipScore += 30;
            } else if (ip.startsWith('172.20.10.')) {
              // Standard iOS Hotspot subnet
              ipScore += 25;
            } else if (ip.startsWith('172.')) {
              ipScore += 20;
            } else if (ip.startsWith('10.')) {
              ipScore += 15;
            }
          } else {
            // Deprioritize non-private (WAN/Cellular carrier) addresses
            ipScore -= 100;
          }

          scored.add((ip: ip, ifaceName: iface.name, score: ipScore));
        }
      }

      scored.sort((a, b) => b.score.compareTo(a.score));

      for (final item in scored) {
        debugPrint(
            '[FluxShare-Network] [HostIP] Discovered candidate: ${item.ip} on ${item.ifaceName} (score=${item.score})');
      }

      return scored.map((item) => item.ip).toList();
    } catch (e) {
      debugPrint('[FluxShare-Network] [HostIP] Error scanning interfaces: $e');
      return [];
    }
  }

  static bool _isExcludedInterface(String name) {
    return name.startsWith('dummy') ||
        name.startsWith('tun') ||
        name.startsWith('utun') ||
        name.startsWith('tap') ||
        name.startsWith('rmnet') ||
        name.startsWith('ccmni') ||
        name.startsWith('pdp') ||
        name.startsWith('wwan') ||
        name.startsWith('qmi') ||
        name.startsWith('clat') ||
        name.startsWith('radio') ||
        name.startsWith('ipsec') ||
        name.startsWith('vboxnet') ||
        name.startsWith('docker') ||
        name.startsWith('virbr') ||
        name.startsWith('sit') ||
        name.startsWith('gre');
  }

  static int _getInterfaceBaseScore(String name) {
    // Android Hotspot / SoftAP interfaces
    if (name.startsWith('ap') ||
        name.startsWith('softap') ||
        name.startsWith('swlan') ||
        name.startsWith('tether') ||
        name.startsWith('hotspot') ||
        name.startsWith('rndis')) {
      return 100;
    }
    // Wi-Fi client and Wi-Fi Direct
    if (name.startsWith('wlan') ||
        name.startsWith('wl') ||
        name.startsWith('wifi') ||
        name.startsWith('p2p')) {
      return 85;
    }
    // Ethernet
    if (name.startsWith('eth') || name.startsWith('en')) {
      return 70;
    }
    return 30;
  }

  /// Calculates the subnet broadcast address for the local IPv4.
  static Future<String> getBroadcastAddress() async {
    final localIp = await getLocalIpAddress();
    if (localIp != null && localIp.contains('.')) {
      final parts = localIp.split('.');
      if (parts.length == 4) {
        return '${parts[0]}.${parts[1]}.${parts[2]}.255';
      }
    }
    return '255.255.255.255';
  }

  /// Returns valid discovery targets (subnet broadcast, gateway/hotspot host unicast, global broadcast).
  /// Targeting the subnet gateway (.1) directly is critical on Android Hotspots where UDP broadcast
  /// may be filtered or isolated by hostapd/iptables between clients.
  static Future<Set<InternetAddress>> getDiscoveryTargets({String? localIpOverride}) async {
    final targets = <InternetAddress>{};
    final allIps = localIpOverride != null
        ? [localIpOverride]
        : await getAllLocalIpAddresses();
    final localIp = localIpOverride ?? await getLocalIpAddress();
    final effectiveIps = allIps.isNotEmpty ? allIps : (localIp != null ? [localIp] : <String>[]);

    for (final ip in effectiveIps) {
      if (ip.contains('.')) {
        final parts = ip.split('.');
        if (parts.length == 4) {
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          // Subnet broadcast
          targets.add(InternetAddress('$prefix.255'));
          // Subnet gateway / hotspot host unicast
          targets.add(InternetAddress('$prefix.1'));
        }
      }
    }

    // Always include global broadcast
    targets.add(InternetAddress('255.255.255.255'));

    // Include common default Android & iOS Hotspot gateway hosts as secondary targets
    if (localIp == null || !localIp.startsWith('192.168.43.')) {
      targets.add(InternetAddress('192.168.43.1'));
      targets.add(InternetAddress('192.168.43.255'));
    }
    if (localIp == null || !localIp.startsWith('172.20.10.')) {
      targets.add(InternetAddress('172.20.10.1'));
    }

    // Include known active peer IPs discovered in swarm / peer presence
    try {
      for (final peer in PeerManager().activePeers) {
        final pip = peer.ip.trim();
        if (isValidIpv4(pip) && pip != localIp) {
          targets.add(InternetAddress(pip));
        }
      }
    } catch (_) {}

    debugPrint('[FluxShare-Network] [DiscoveryTargets] Resolved targets for $localIp: '
        '${targets.map((t) => t.address).toList()}');

    return targets;
  }

  /// Tests HTTP reachability against a peer's health endpoint.
  static Future<bool> testPeerConnectivity(
    String peerIp,
    int peerPort, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('http://$peerIp:$peerPort/health');
      final req = await client.getUrl(uri).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      final isOk = resp.statusCode == HttpStatus.ok;
      debugPrint('[FluxShare-Network] [Connectivity] Health check http://$peerIp:$peerPort/health -> isOk=$isOk');
      return isOk;
    } catch (e) {
      debugPrint('[FluxShare-Network] [Connectivity] Health check http://$peerIp:$peerPort/health failed: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// Pings an address using raw socket to check reachability.
  static Future<bool> isHostReachable(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checks if two IPv4 addresses are on the same /24 subnet.
  static bool isSameSubnet(String ip1, String ip2) {
    final p1 = ip1.split('.');
    final p2 = ip2.split('.');
    if (p1.length == 4 && p2.length == 4) {
      return p1[0] == p2[0] && p1[1] == p2[1] && p1[2] == p2[2];
    }
    return false;
  }

  /// Validates standard IPv4 formatting (e.g. "192.168.43.1").
  static bool isValidIpv4(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final val = int.tryParse(p);
      if (val == null || val < 0 || val > 255) return false;
    }
    return true;
  }

  /// Checks if given IP string is a valid private IPv4 range.
  static bool isPrivateIp(String ip) {
    try {
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4) return false;

      // 10.0.0.0/8
      if (parts[0] == 10) return true;
      // 172.16.0.0/12
      if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
      // 192.168.0.0/16
      if (parts[0] == 192 && parts[1] == 168) return true;

      return false;
    } catch (_) {
      return false;
    }
  }
}
