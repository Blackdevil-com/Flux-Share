import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/app_settings.dart';

void main() {
  group('AppSettings Unit Tests', () {
    test('Defaults are sensible and non-empty', () {
      final settings = AppSettings();
      expect(settings.deviceName.isNotEmpty, isTrue);
      expect(settings.maxParallelConnections, equals(5));
      expect(settings.autoAccept, isFalse);
      expect(settings.showNotifications, isTrue);
    });

    test('Parallel connections clamps between 1 and 10', () async {
      final settings = AppSettings();
      await settings.setMaxParallelConnections(0);
      expect(settings.maxParallelConnections, equals(1));

      await settings.setMaxParallelConnections(15);
      expect(settings.maxParallelConnections, equals(10));

      await settings.setMaxParallelConnections(6);
      expect(settings.maxParallelConnections, equals(6));
    });

    test('Device name update trims whitespace', () async {
      final settings = AppSettings();
      await settings.setDeviceName('  Test Phone  ');
      expect(settings.deviceName, equals('Test Phone'));
    });
  });
}
