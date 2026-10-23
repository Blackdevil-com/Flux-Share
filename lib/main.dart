import 'package:flutter/material.dart';
import 'ai/ai_service.dart';
import 'app/app.dart';
import 'app/theme.dart';
import 'discovery/discovery_service.dart';
import 'metrics/metrics_collector.dart';
import 'models/app_settings.dart';
import 'network/local_server.dart';
import 'peer/peer_manager.dart';
import 'repositories/transfer_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize persistence and managers
  await AppSettings().init();
  await MetricsCollector().init();
  await TransferRepository().init();
  await AIService().init();
  PeerManager().init();

  // Start local HTTP server to bind listening port before advertising presence
  final server = LocalServer();
  final serverPort = await server.start();
  DiscoveryService().startPeerPresenceListener(
    peerId: server.localPeerId,
    deviceName: server.localDeviceName,
    platform: server.platform,
    serverPort: serverPort,
  );

  runApp(const FluxShareApp());
}

class FluxShareApp extends StatelessWidget {
  const FluxShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FluxShare',
      theme: AppTheme.lightTheme,
      home: const MainShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}
