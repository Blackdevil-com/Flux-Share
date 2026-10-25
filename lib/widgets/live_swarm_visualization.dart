import 'dart:async';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../transfer/transfer_engine.dart';

/// Live swarm network visualization widget displaying actual peers, real-time chunk distribution,
/// AIMD concurrency saturation, and active scheduler state.
/// Shows explicit empty state when no active transfer is running.
class LiveSwarmVisualization extends StatefulWidget {
  final TransferEngine? engine;
  final String schedulerMode;

  const LiveSwarmVisualization({
    super.key,
    this.engine,
    this.schedulerMode = 'round-robin',
  });

  @override
  State<LiveSwarmVisualization> createState() => _LiveSwarmVisualizationState();
}

class _LiveSwarmVisualizationState extends State<LiveSwarmVisualization> {
  StreamSubscription<TransferProgressEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(LiveSwarmVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.engine?.progressStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.engine == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.s20),
        decoration: BoxDecoration(
          color: AppColors.lightGray,
          borderRadius: AppShapes.cardBorderRadius,
          border: Border.all(color: AppColors.borderGray),
        ),
        child: const Column(
          children: [
            Icon(Icons.hub_outlined, size: 40, color: AppColors.mediumGray),
            SizedBox(height: AppSpacing.s8),
            Text(
              'No Active Swarm Transfer',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlack,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Connect to a room or initiate a transfer to visualize live peer coordination.',
              style: TextStyle(fontSize: 12, color: AppColors.mediumGray),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final engine = widget.engine!;
    final peers = engine.swarmPeers;
    final totalChunks = engine.manifest.chunkCount;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  const Text(
                    'LIVE SWARM TOPOLOGY',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primaryBlack,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  widget.schedulerMode.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.backgroundWhite,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            'Coordinator: ${engine.coordinatorPeerId}',
            style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
          ),
          const SizedBox(height: AppSpacing.s8),
          const Divider(height: 1, color: AppColors.borderGray),
          const SizedBox(height: AppSpacing.s12),

          // Swarm Peer Cards
          if (peers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'Searching for cooperative peers...',
                style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: peers.length,
              separatorBuilder: (context, _) => const SizedBox(height: AppSpacing.s8),
              itemBuilder: (context, index) {
                final peer = peers[index];
                final isCoordinator = peer.peerId == engine.coordinatorPeerId;
                final chunksHeld = peer.availableChunks.length;
                final pctHeld = totalChunks > 0 ? (chunksHeld / totalChunks * 100).toInt() : 0;

                return Container(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  decoration: BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderGray),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: isCoordinator ? AppColors.primaryBlack : AppColors.darkGray,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isCoordinator ? Icons.dns_rounded : Icons.phone_android_rounded,
                          color: AppColors.backgroundWhite,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  peer.deviceName.isNotEmpty ? peer.deviceName : peer.peerId,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlack,
                                  ),
                                ),
                                if (isCoordinator) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryBlack,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'SOURCE',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.backgroundWhite,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${peer.ip}:${peer.httpPort} • $chunksHeld/$totalChunks chunks ($pctHeld%)',
                              style: const TextStyle(fontSize: 12, color: AppColors.mediumGray),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            peer.emaThroughput > 0
                                ? '${peer.emaThroughput.toStringAsFixed(1)} MB/s'
                                : 'Active',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                          Text(
                            peer.connectionStatus,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: peer.connectionStatus == 'available'
                                  ? Colors.green[700]
                                  : Colors.orange[800],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
