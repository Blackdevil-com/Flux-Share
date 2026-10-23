import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/discovery/discovery_packet.dart';

void main() {
  group('DiscoveryPacket Tests', () {
    test('Encodes and decodes DISCOVER_ROOM packet', () {
      final packet = DiscoveryPacket(
        action: 'DISCOVER_ROOM',
        pin: '1234',
      );

      final encoded = packet.encode();
      final decoded = DiscoveryPacket.tryDecode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.action, equals('DISCOVER_ROOM'));
      expect(decoded.pin, equals('1234'));
    });

    test('Encodes and decodes ROOM_FOUND packet with server IP and port', () {
      final packet = DiscoveryPacket(
        action: 'ROOM_FOUND',
        pin: '5678',
        roomId: 'room_abc',
        ip: '192.168.1.50',
        port: 8080,
        deviceName: "Vicky's Phone",
      );

      final encoded = packet.encode();
      final decoded = DiscoveryPacket.tryDecode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.action, equals('ROOM_FOUND'));
      expect(decoded.pin, equals('5678'));
      expect(decoded.ip, equals('192.168.1.50'));
      expect(decoded.port, equals(8080));
      expect(decoded.deviceName, equals("Vicky's Phone"));
    });

    test('Encodes and decodes PEER_ANNOUNCE packet', () {
      final packet = DiscoveryPacket(
        action: 'PEER_ANNOUNCE',
        peerId: 'peer_xyz',
        deviceName: 'Motorola G',
        platform: 'android',
        ip: '192.168.1.88',
        port: 8080,
      );

      final encoded = packet.encode();
      final decoded = DiscoveryPacket.tryDecode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.action, equals('PEER_ANNOUNCE'));
      expect(decoded.peerId, equals('peer_xyz'));
      expect(decoded.deviceName, equals('Motorola G'));
    });

    test('Returns null on invalid JSON payload', () {
      final decoded = DiscoveryPacket.tryDecode('NOT_JSON_DATA');
      expect(decoded, isNull);
    });
  });
}
