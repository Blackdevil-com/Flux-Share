import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/models/chunk.dart';
import 'package:fluxshare/models/manifest.dart';
import 'package:fluxshare/models/peer.dart';
import 'package:fluxshare/network/local_server.dart';
import 'package:fluxshare/scheduler/round_robin_scheduler.dart';
import 'package:fluxshare/transfer/transfer_engine.dart';
import 'package:fluxshare/widgets/live_swarm_visualization.dart';

void main() {
  group('LiveSwarmVisualization Widget Tests', () {
    testWidgets('Renders empty state when no active engine is present', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiveSwarmVisualization(engine: null),
          ),
        ),
      );

      expect(find.text('No Active Swarm Transfer'), findsOneWidget);
      expect(
        find.text('Connect to a room or initiate a transfer to visualize live peer coordination.'),
        findsOneWidget,
      );
    });

    testWidgets('Renders swarm topology and peer details when engine has active peers', (tester) async {
      const manifest = Manifest(
        fileId: 'test-manifest-01',
        fileName: 'presentation.pdf',
        mimeType: 'application/pdf',
        fileSize: 32768,
        fileSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        chunkCount: 2,
        chunkSize: 16384,
        chunks: [
          ChunkMeta(chunkId: 0, offset: 0, length: 16384, sha256: 'hash0'),
          ChunkMeta(chunkId: 1, offset: 16384, length: 16384, sha256: 'hash1'),
        ],
      );

      final peerA = PeerInfo(
        peerId: 'peer-alpha',
        deviceName: "Alice's Galaxy S24",
        platform: 'android',
        ip: '192.168.1.105',
        httpPort: 8080,
        webSocketPort: 8080,
        availableChunks: {0, 1},
        emaThroughput: 14.5,
        connectionStatus: 'available',
      );

      final engine = TransferEngine(
        manifest: manifest,
        destinationFile: File('dummy_destination.bin'),
        swarmPeers: [peerA],
        localServer: LocalServer(),
        localPeerId: 'rx-self',
        coordinatorPeerId: 'peer-alpha',
        scheduler: RoundRobinScheduler(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LiveSwarmVisualization(
                engine: engine,
                schedulerMode: 'sequential-priority',
              ),
            ),
          ),
        ),
      );

      // Verify topology title and scheduler tag
      expect(find.text('LIVE SWARM TOPOLOGY'), findsOneWidget);
      expect(find.text('SEQUENTIAL-PRIORITY'), findsOneWidget);

      // Verify peer card content
      expect(find.text("Alice's Galaxy S24"), findsOneWidget);
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.text('14.5 MB/s'), findsOneWidget);
      expect(find.text('available'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await engine.dispose();
    });
  });
}
