import 'dart:io';
import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../metrics/metrics_collector.dart';
import '../../metrics/metrics_models.dart';
import '../../mock/mock_data.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';

class ReceiverDetailItem {
  final String name;
  final DevicePlatform platform;
  final String throughput;

  const ReceiverDetailItem({
    required this.name,
    required this.platform,
    required this.throughput,
  });
}

class TransferDetailsScreen extends StatelessWidget {
  final FileInfo? fileInfo;
  final String durationText;
  final String avgSpeedText;
  final int receiversCount;
  final TransferMetrics? metrics;

  const TransferDetailsScreen({
    super.key,
    this.fileInfo,
    this.durationText = '01:52',
    this.avgSpeedText = '42 MB/s',
    this.receiversCount = 3,
    this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    final collector = MetricsCollector();
    final effectiveMetrics = metrics ??
        (collector.getHistory().isNotEmpty ? collector.getHistory().last : null);

    final file = fileInfo ??
        (effectiveMetrics != null
            ? FileInfo(
                id: effectiveMetrics.fileId,
                name: effectiveMetrics.fileName,
                sizeBytes: effectiveMetrics.fileSize,
                formattedSize: _formatBytes(effectiveMetrics.fileSize),
                extension: effectiveMetrics.fileName.contains('.')
                    ? effectiveMetrics.fileName.split('.').last
                    : '',
                type: FileType.Other,
              )
            : MockData.mockFiles[0]);

    final duration = effectiveMetrics != null
        ? '${(effectiveMetrics.totalDistributionTimeMillis / 1000).toStringAsFixed(1)}s'
        : durationText;
    final speed = effectiveMetrics != null
        ? '${effectiveMetrics.aggregateThroughputMbps.toStringAsFixed(1)} Mbps'
        : avgSpeedText;
    final scheduler = effectiveMetrics?.schedulerMode.toUpperCase() ?? 'ROUND-ROBIN';
    final networkMode = effectiveMetrics?.networkMode.toUpperCase() ?? 'WIFI';
    final chunks = effectiveMetrics?.chunkCount.toString() ?? '4,608';
    final retries = effectiveMetrics?.retransmissionCount.toString() ?? '0';
    final ttfb = effectiveMetrics != null && effectiveMetrics.avgTimeToFirstByteMillis > 0
        ? '${effectiveMetrics.avgTimeToFirstByteMillis.toStringAsFixed(0)} ms'
        : 'N/A';
    final preview = effectiveMetrics?.timeToFirstPreviewReadyMillis != null
        ? '${effectiveMetrics!.timeToFirstPreviewReadyMillis} ms'
        : 'N/A';

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Transfer Details & Report'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // File details card
              FileCard(fileInfo: file),
              const SizedBox(height: AppSpacing.s24),

              // Transfer statistics table/grid
              const SectionHeader(title: 'Transfer & Transport Statistics'),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: AppShapes.cardBorderRadius,
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Column(
                  children: [
                    _buildStatRow('File Size', file.formattedSize),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Duration', duration),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Aggregate Speed', speed),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Scheduler Mode', scheduler),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Network Mode', networkMode),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Total Chunks', chunks),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Retransmissions / Retries', retries),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Avg Time to First Byte (TTFB)', ttfb),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Time to Preview Ready', preview),
                    if (effectiveMetrics != null) ...[
                      const Divider(height: 1, color: AppColors.borderGray),
                      _buildStatRow(
                        'Sender Upload Volume',
                        _formatBytes(effectiveMetrics.senderUploadVolumeBytes),
                      ),
                      const Divider(height: 1, color: AppColors.borderGray),
                      _buildStatRow(
                        'Cooperative Forward Volume',
                        _formatBytes(effectiveMetrics.cooperativeForwardingVolumeBytes),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s24),

              // Export CSV Button (Phase D3)
              PrimaryButton(
                text: 'EXPORT EVALUATION REPORT (CSV)',
                icon: Icons.file_download_outlined,
                onPressed: () async {
                  try {
                    final file = await collector.exportMetricsCsvFile();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Metrics exported: ${file.path}'),
                          backgroundColor: AppColors.primaryBlack,
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Export failed: $e')),
                      );
                    }
                  }
                },
              ),
              const SizedBox(height: AppSpacing.s24),

              // Peer breakdown
              if (effectiveMetrics != null && effectiveMetrics.peerUtilizations.isNotEmpty) ...[
                const SectionHeader(title: 'Per-Peer Utilization Breakdown'),
                Column(
                  children: effectiveMetrics.peerUtilizations.values.map((util) {
                    final uploaded = _formatBytes(util.bytesUploaded);
                    final received = _formatBytes(util.bytesReceived);
                    final pct = (util.utilizationFraction * 100).toInt();

                    return Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.s12),
                      padding: const EdgeInsets.all(AppSpacing.s16),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.borderGray),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: AppColors.primaryBlack,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.devices_rounded,
                              color: AppColors.backgroundWhite,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  util.peerId,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlack,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Role: ${util.role} • Up: $uploaded • Down: $received',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.mediumGray,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '$pct% Util',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.mediumGray,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
