import 'dart:io';
import 'dart:async';

/// Network utilities for interface detection, IP resolution, and reachability.
class NetworkUtils {
  /// Discovers local non-loopback IPv4 address on active LAN interfaces.
  /// Prioritizes Wi-Fi (wlan, ap, p2p) and Ethernet (eth), filtering out virtual/VPN/cellular.
  static Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      // Prioritize Wi-Fi and Ethernet
      interfaces.sort((a, b) {
        final aName = a.name.toLowerCase();
        final bName = b.name.toLowerCase();
        int scoreA = 0;
        int scoreB = 0;
        if (aName.startsWith('wlan') || aName.startsWith('ap') || aName.startsWith('p2p') || aName.startsWith('en')) {
          scoreA = 3;
        } else if (aName.startsWith('eth')) {
          scoreA = 2;
        }
        if (bName.startsWith('wlan') || bName.startsWith('ap') || bName.startsWith('p2p') || bName.startsWith('en')) {
          scoreB = 3;
        } else if (bName.startsWith('eth')) {
          scoreB = 2;
        }
        return scoreB.compareTo(scoreA);
      });

      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.startsWith('dummy') ||
            name.startsWith('tun') ||
            name.startsWith('utun') ||
            name.startsWith('tap') ||
            name.startsWith('rmnet') ||
            name.startsWith('pdp') ||
            name.startsWith('ipsec') ||
            name.startsWith('vboxnet')) {
          continue;
        }

        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback &&
              !ip.startsWith('127.') &&
              !ip.startsWith('169.254.') &&
              ip.contains('.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
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

  /// Tests HTTP reachability against a peer's health endpoint.
  static Future<bool> testPeerConnectivity(String peerIp, int peerPort) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('http://$peerIp:$peerPort/health');
      final req = await client.getUrl(uri);
      final resp = await req.close();
      return resp.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
