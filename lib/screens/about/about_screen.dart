import 'package:flutter/material.dart';
import '../../app/theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('About'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s24,
            vertical: AppSpacing.s20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: AppSpacing.s16),
              // Centered FluxShareLogo (SEND ↔ RECEIVE)
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.primaryBlack,
                    borderRadius: BorderRadius.circular(20.0),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.swap_horiz_rounded,
                      color: AppColors.backgroundWhite,
                      size: 44,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              const Text(
                'FluxShare',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlack,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              const Text(
                'Version 1.0.0',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.mediumGray,
                ),
              ),
              const SizedBox(height: AppSpacing.s12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Fast. Offline. Together.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlack,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s20),
              const Text(
                'A simple and powerful way to share files with multiple nearby devices — no internet required.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: AppColors.darkGray,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s32),

              // Navigation links dialogs
              Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: AppShapes.cardBorderRadius,
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Column(
                  children: [
                    ListTile(
                      title: const Text(
                        'Privacy Policy',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryBlack,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.darkGray,
                      ),
                      onTap: () => _showPrivacyPolicyDialog(context),
                    ),
                    const Divider(height: 1, color: AppColors.borderGray),
                    ListTile(
                      title: const Text(
                        'Open Source Licenses',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryBlack,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.darkGray,
                      ),
                      onTap: () => _showOpenSourceLicensesDialog(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s32),
              const Text(
                'Made with ♥ for a connected world.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.mediumGray,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s16),
            ],
          ),
        ),
      ),
    );
  }

  void _showPrivacyPolicyDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Privacy Policy',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        content: const SingleChildScrollView(
          child: Text(
            'FluxShare operates strictly peer-to-peer using local Wi-Fi and Wi-Fi Direct. '
            'No personal data, telemetry, or file contents are ever uploaded to external servers or cloud services. '
            'Your transfers remain completely private and stay on your local network.',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.darkGray,
              height: 1.4,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showOpenSourceLicensesDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Open Source Licenses',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        content: const SingleChildScrollView(
          child: Text(
            'FluxShare is built using open source software:\n\n'
            '• Flutter SDK (BSD-3-Clause)\n'
            '• Material Design Components (Apache 2.0)\n'
            '• WebSocket P2P Transport (MIT)\n'
            '• Chunk Reservation Engine (MIT)',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.darkGray,
              height: 1.4,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
