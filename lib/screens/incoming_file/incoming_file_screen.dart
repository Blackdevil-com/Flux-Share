import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../mock/mock_data.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_progress_screen.dart';

class IncomingFileScreen extends StatelessWidget {
  final FileInfo? fileInfo;
  final String senderName;

  const IncomingFileScreen({
    super.key,
    this.fileInfo,
    this.senderName = "Akash's Android",
  });

  @override
  Widget build(BuildContext context) {
    final file = fileInfo ?? MockData.mockFiles[0]; // Project_Video.mp4, 4.8 GB

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Incoming File'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.s20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sender info banner
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.s16),
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.borderGray),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                              color: AppColors.primaryBlack,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.phone_android_rounded,
                              color: AppColors.backgroundWhite,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$senderName wants to send you a file',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryBlack,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Wi-Fi Direct Connection',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.mediumGray,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s24),

                    // Large file icon and file details card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.s24),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.primaryBlack, width: 1.5),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: AppColors.lightGray,
                              borderRadius: BorderRadius.circular(20.0),
                              border: Border.all(color: AppColors.borderGray),
                            ),
                            child: const Icon(
                              Icons.movie_outlined,
                              color: AppColors.primaryBlack,
                              size: 40,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.s16),
                          Text(
                            file.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.s4),
                          Text(
                            '${file.formattedSize} • ${file.extension.toUpperCase()}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.mediumGray,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s24),

                    // Metadata rows
                    const SectionHeader(title: 'File Details'),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.backgroundWhite,
                        borderRadius: AppShapes.cardBorderRadius,
                        border: Border.all(color: AppColors.borderGray),
                      ),
                      child: Column(
                        children: [
                          _buildMetadataRow(
                            label: 'File type',
                            value: '${file.type.displayName} ${file.extension.toUpperCase()}',
                            icon: Icons.category_outlined,
                          ),
                          const Divider(height: 1, color: AppColors.borderGray),
                          _buildMetadataRow(
                            label: 'File size',
                            value: file.formattedSize,
                            icon: Icons.data_usage_rounded,
                          ),
                          const Divider(height: 1, color: AppColors.borderGray),
                          _buildMetadataRow(
                            label: 'Sender',
                            value: senderName,
                            icon: Icons.person_outline_rounded,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Action buttons
            Container(
              padding: const EdgeInsets.all(AppSpacing.s16),
              decoration: const BoxDecoration(
                color: AppColors.backgroundWhite,
                border: Border(
                  top: BorderSide(color: AppColors.borderGray, width: 1.0),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PrimaryButton(
                    text: 'ACCEPT',
                    icon: Icons.check_circle_outline_rounded,
                    onPressed: () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (context) => TransferProgressScreen(
                            fileInfo: file,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.s12),
                  SecondaryButton(
                    text: 'DECLINE',
                    icon: Icons.close_rounded,
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataRow({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.darkGray),
          const SizedBox(width: AppSpacing.s12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.mediumGray,
            ),
          ),
          const Spacer(),
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
