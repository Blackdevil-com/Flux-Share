import 'package:flutter/material.dart';
import '../../app/theme.dart';
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

  const TransferDetailsScreen({
    super.key,
    this.fileInfo,
    this.durationText = '01:52',
    this.avgSpeedText = '42 MB/s',
    this.receiversCount = 3,
  });

  @override
  Widget build(BuildContext context) {
    final file = fileInfo ?? MockData.mockFiles[0]; // Project_Video.mp4, 4.8 GB

    final receiverDetails = [
      const ReceiverDetailItem(
        name: "Akash's iPhone",
        platform: DevicePlatform.iPhone,
        throughput: '78 MB/s',
      ),
      const ReceiverDetailItem(
        name: "Rohan's Android",
        platform: DevicePlatform.Android,
        throughput: '52 MB/s',
      ),
      const ReceiverDetailItem(
        name: "Dev's Tablet",
        platform: DevicePlatform.Android,
        throughput: '41 MB/s',
      ),
    ];

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Transfer Details'),
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
              const SectionHeader(title: 'Transfer Statistics'),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: AppShapes.cardBorderRadius,
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Column(
                  children: [
                    _buildStatRow('File size', file.formattedSize),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Duration', durationText),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Average speed', avgSpeedText),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Receivers', '$receiversCount'),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Total Chunks', '4,608'),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Successful Chunks', '4,608'),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Failed Chunks', '0'),
                    const Divider(height: 1, color: AppColors.borderGray),
                    _buildStatRow('Retries', '0'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s24),

              // Receiver Details list
              const SectionHeader(title: 'Receiver Details'),
              Column(
                children: receiverDetails.map((receiver) {
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
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.lightGray,
                            borderRadius: BorderRadius.circular(10.0),
                            border: Border.all(color: AppColors.borderGray),
                          ),
                          child: Icon(
                            receiver.platform == DevicePlatform.iPhone
                                ? Icons.phone_iphone_rounded
                                : Icons.phone_android_rounded,
                            color: AppColors.primaryBlack,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                receiver.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryBlack,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                receiver.platform.displayName,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.mediumGray,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              receiver.throughput,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Throughput',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.mediumGray,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
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
}
