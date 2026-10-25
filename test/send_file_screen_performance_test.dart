import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/file_info.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/screens/send_file/send_file_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fluxshare_screen_test_');
    NetworkUtils.customLocalIp = '192.168.1.100';
    ManifestCache.instance.setCustomCacheDir(tempDir);
    ManifestCache.instance.clearMemoryCache();
    ManifestService.disableIsolatesForTesting = true;
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    ManifestService.disableIsolatesForTesting = false;
    await ManifestCache.instance.clear();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('SendFileScreen Manifest Pipeline Tests', () {
    testWidgets('1. SendFileScreen displays file info immediately and shows readiness upon completion', (tester) async {
      final file = File('${tempDir.path}/presentation.pdf');
      file.writeAsStringSync('sample pdf contents for testing manifest pipeline');

      final initialFile = FileInfo.fromMetadata(
        path: file.path,
        name: 'presentation.pdf',
        sizeBytes: 48,
      );

      const dummyManifest = Manifest(
        fileId: 'm1_test',
        fileName: 'presentation.pdf',
        fileSize: 48,
        mimeType: 'application/pdf',
        chunkSize: 512 * 1024,
        chunkCount: 1,
        fileSha256: 'sha256_mock_hash_for_test',
        chunks: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SendFileScreen(
            initialFile: initialFile,
            initialManifest: dummyManifest,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify file info is visible immediately
      expect(find.text('presentation.pdf'), findsOneWidget);
      expect(find.textContaining('Document'), findsOneWidget);

      // Status updates to Manifest Ready with green check
      expect(find.textContaining('Manifest Ready · 1 chunks · SHA-256 verified'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
    });

    testWidgets('2. Room PIN and Direct Host are displayed cleanly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SendFileScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('ROOM PIN FOR RECEIVERS'), findsOneWidget);
      expect(find.textContaining('ROOM PIN:'), findsOneWidget);
      expect(find.textContaining('Direct Host: 192.168.1.100'), findsOneWidget);
    });
  });
}
