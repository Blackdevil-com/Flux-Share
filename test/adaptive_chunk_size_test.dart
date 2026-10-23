import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';

void main() {
  group('Adaptive Chunk Size Tests (Part 6)', () {
    test('Selects 512 KB chunks for files <= 10 MB', () {
      expect(ManifestService.selectAdaptiveChunkSize(5 * 1024 * 1024), equals(512 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(10 * 1024 * 1024), equals(512 * 1024));
    });

    test('Selects 1 MB chunks for files 10 MB - 100 MB', () {
      expect(ManifestService.selectAdaptiveChunkSize(50 * 1024 * 1024), equals(1024 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(100 * 1024 * 1024), equals(1024 * 1024));
    });

    test('Selects 2 MB chunks for files 100 MB - 500 MB', () {
      expect(ManifestService.selectAdaptiveChunkSize(250 * 1024 * 1024), equals(2 * 1024 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(500 * 1024 * 1024), equals(2 * 1024 * 1024));
    });

    test('Selects 4 MB chunks for files 500 MB - 1 GB', () {
      expect(ManifestService.selectAdaptiveChunkSize(750 * 1024 * 1024), equals(4 * 1024 * 1024));
      expect(ManifestService.selectAdaptiveChunkSize(1024 * 1024 * 1024), equals(4 * 1024 * 1024));
    });

    test('Selects 8 MB chunks for files > 1 GB', () {
      expect(ManifestService.selectAdaptiveChunkSize(2 * 1024 * 1024 * 1024), equals(8 * 1024 * 1024));
    });
  });
}
