import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/models/connected_receiver.dart';
import 'package:fluxshare/models/models.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/network/network_utils.dart';
import 'package:fluxshare/services/storage_path_service.dart';
import 'package:fluxshare/transfer/transfer_session_manager.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalServer hostServer;
  late int hostPort;

  setUp(() async {
    HttpOverrides.global = null;
    NetworkUtils.customLocalIp = '127.0.0.1';

    tempDir = await Directory.systemTemp.createTemp('fluxshare_regression_');
    StoragePathService.customSaveDirectory = Directory('${tempDir.path}/Downloads');
    await StoragePathService.customSaveDirectory!.create(recursive: true);

    hostServer = LocalServer();
    hostServer.enableServedBytesAsProgressFallback = true;
    hostPort = await hostServer.start(preferredPort: 19891);
    hostServer.clearReceivers();
  });

  tearDown(() async {
    NetworkUtils.customLocalIp = null;
    StoragePathService.customSaveDirectory = null;
    hostServer.clearBatch();
    await hostServer.stop();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('352 KB single-chunk transfer completes exactly once without feedback loop', () async {
    final pdfFile = File('${tempDir.path}/test_single_chunk.pdf');
    await pdfFile.writeAsBytes(List.generate(352 * 1024, (i) => i % 256));

    final manifest = await ManifestService.createManifest(pdfFile, chunkSize: 512 * 1024);
    expect(manifest.chunkCount, 1);
    final batchManifest = BatchManifest.fromSingleManifest(manifest);

    hostServer.setBatchManifests([(manifest: manifest, file: pdfFile)]);

    final sessionManager = TransferSessionManager.instance;
    await sessionManager.startHostSession(
      server: hostServer,
      batchManifest: batchManifest,
      receivers: [],
      roomPin: '4321',
    );

    hostServer.updateReceiver(ConnectedReceiver(
      peerId: 'rx_1',
      deviceName: 'Pixel Receiver',
      platform: DevicePlatform.Android,
      ip: '127.0.0.1',
      status: ReceiverStatus.connected,
      lastSeen: DateTime.now(),
    ));

    int completionCount = 0;
    final sub = sessionManager.progressStream.listen((snap) {
      if (snap.isCompleted) {
        completionCount++;
        // Host cleans up batch on completion
        hostServer.clearBatch(notify: false);
      }
    });

    // Request chunk 0
    final chunk0Url = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/0');
    final res = await http.get(chunk0Url, headers: {'X-Peer-Id': 'rx_1'});
    expect(res.statusCode, 200);
    expect(res.bodyBytes.length, 352 * 1024);

    // Wait for all stream events
    await Future.delayed(const Duration(milliseconds: 200));

    // Must be invoked exactly once, never re-entrant or looping
    expect(completionCount, equals(1));
    await sub.cancel();
  });

  test('Event loop responsiveness: event loop is never starved upon completion', () async {
    final pdfFile = File('${tempDir.path}/test_starvation.pdf');
    await pdfFile.writeAsBytes(List.generate(352 * 1024, (i) => i % 256));

    final manifest = await ManifestService.createManifest(pdfFile, chunkSize: 512 * 1024);
    final batchManifest = BatchManifest.fromSingleManifest(manifest);

    hostServer.setBatchManifests([(manifest: manifest, file: pdfFile)]);

    final sessionManager = TransferSessionManager.instance;
    await sessionManager.startHostSession(
      server: hostServer,
      batchManifest: batchManifest,
      receivers: [],
      roomPin: '5678',
    );

    hostServer.updateReceiver(ConnectedReceiver(
      peerId: 'rx_responsive',
      deviceName: 'Receiver Responsiveness',
      platform: DevicePlatform.Android,
      ip: '127.0.0.1',
      status: ReceiverStatus.connected,
      lastSeen: DateTime.now(),
    ));

    bool timerFired = false;
    final timer = Timer(Duration.zero, () {
      timerFired = true;
    });

    final chunk0Url = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/0');
    final res = await http.get(chunk0Url, headers: {'X-Peer-Id': 'rx_responsive'});
    expect(res.statusCode, 200);

    await Future.delayed(const Duration(milliseconds: 100));

    expect(timerFired, isTrue, reason: 'Zero-duration timer must fire promptly without event loop starvation');
    timer.cancel();
  });

  test('1-to-many transfer: receiver 1 completing does NOT break receiver 2 downloading', () async {
    // 2-chunk file
    final file = File('${tempDir.path}/test_multi_rx.bin');
    await file.writeAsBytes(List.generate(1024 * 1024, (i) => (i * 7) % 256));

    final manifest = await ManifestService.createManifest(file, chunkSize: 512 * 1024);
    expect(manifest.chunkCount, 2);
    final batchManifest = BatchManifest.fromSingleManifest(manifest);

    hostServer.setBatchManifests([(manifest: manifest, file: file)]);

    final sessionManager = TransferSessionManager.instance;
    await sessionManager.startHostSession(
      server: hostServer,
      batchManifest: batchManifest,
      receivers: [],
      roomPin: '8888',
    );

    // Register 2 receivers
    hostServer.updateReceiver(ConnectedReceiver(
      peerId: 'receiver_alpha',
      deviceName: 'Alpha Device',
      platform: DevicePlatform.Android,
      ip: '127.0.0.1',
      status: ReceiverStatus.connected,
      lastSeen: DateTime.now(),
    ));

    hostServer.updateReceiver(ConnectedReceiver(
      peerId: 'receiver_beta',
      deviceName: 'Beta Device',
      platform: DevicePlatform.Android,
      ip: '127.0.0.1',
      status: ReceiverStatus.connected,
      lastSeen: DateTime.now(),
    ));

    // Receiver Alpha downloads both chunks (finishes 100%)
    final urlChunk0 = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/0');
    final urlChunk1 = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/1');

    final resAlpha0 = await http.get(urlChunk0, headers: {'X-Peer-Id': 'receiver_alpha'});
    final resAlpha1 = await http.get(urlChunk1, headers: {'X-Peer-Id': 'receiver_alpha'});
    expect(resAlpha0.statusCode, 200);
    expect(resAlpha1.statusCode, 200);

    // Allow Alpha completion to process
    await Future.delayed(const Duration(milliseconds: 100));

    // Assert session is NOT completed because Beta is still at 0%
    expect(sessionManager.currentSnapshot?.isCompleted, isFalse);

    // Receiver Beta downloads chunk 0 and chunk 1 now
    final resBeta0 = await http.get(urlChunk0, headers: {'X-Peer-Id': 'receiver_beta'});
    final resBeta1 = await http.get(urlChunk1, headers: {'X-Peer-Id': 'receiver_beta'});
    expect(resBeta0.statusCode, 200, reason: 'Chunk 0 must still be available for receiver Beta');
    expect(resBeta1.statusCode, 200, reason: 'Chunk 1 must still be available for receiver Beta');

    await Future.delayed(const Duration(milliseconds: 100));

    // Now both receivers finished, so session completes
    expect(sessionManager.currentSnapshot?.isCompleted, isTrue);
    expect(sessionManager.currentSnapshot?.progressPercent, 100.0);
  });

  test('Invalid chunk ID returns 404 Not Found cleanly without 500 error', () async {
    final file = File('${tempDir.path}/test_404.bin');
    await file.writeAsBytes(List.generate(100 * 1024, (i) => i % 256));

    final manifest = await ManifestService.createManifest(file, chunkSize: 512 * 1024);
    hostServer.setBatchManifests([(manifest: manifest, file: file)]);

    final invalidChunkUrl = Uri.parse('http://127.0.0.1:$hostPort/file/${manifest.fileId}/chunk/999');
    final res = await http.get(invalidChunkUrl);
    expect(res.statusCode, 404);
  });
}
