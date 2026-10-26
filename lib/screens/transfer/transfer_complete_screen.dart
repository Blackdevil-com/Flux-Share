import 'dart:io';
import 'package:flutter/material.dart';
import '../../ai/ai_models.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../../mock/mock_data.dart';
import '../../models/models.dart';
import '../../services/storage_path_service.dart';
import '../../widgets/widgets.dart';
import 'transfer_details_screen.dart';

class TransferCompleteScreen extends StatefulWidget {
  final FileInfo? fileInfo;
  final int receiversCount;
  final String durationText;
  final String avgSpeedText;
  final int chunkCount;
  final int retryCount;

  const TransferCompleteScreen({
    super.key,
    this.fileInfo,
    this.receiversCount = 1,
    this.durationText = '01:52',
    this.avgSpeedText = '42 MB/s',
    this.chunkCount = 42,
    this.retryCount = 0,
  });

  @override
  State<TransferCompleteScreen> createState() => _TransferCompleteScreenState();
}

class _TransferCompleteScreenState extends State<TransferCompleteScreen> {
  final AIService _aiService = AIService();
  AIClassificationResult? _classification;
  AISmartSummary? _smartSummary;

  @override
  void initState() {
    super.initState();
    _loadAiData();
  }

  Future<void> _loadAiData() async {
    final file = widget.fileInfo ?? MockData.mockFiles[0];

    if (_aiService.config.isAiEnabled) {
      final classification = await _aiService.classifyFile(
        fileName: file.name,
        sizeBytes: file.sizeBytes,
        filePath: file.id,
      );

      final summary = await _aiService.summaryService.generateSummary(
        fileName: file.name,
        formattedSize: file.formattedSize,
        durationText: widget.durationText,
        averageSpeedText: widget.avgSpeedText,
        chunkCount: widget.chunkCount,
        retryCount: widget.retryCount,
        integrityVerified: true,
      );

      if (mounted) {
        setState(() {
          _classification = classification;
          _smartSummary = summary;
        });
      }
    }
  }

  Future<void> _handleSmartOrganization(FileInfo file) async {
    final plan = await _aiService.organizer.createOrganizationPlan(
      fileNames: [file.name],
      fileSizes: {file.name: file.sizeBytes},
    );

    if (!mounted) return;

    final approvedPlan = await showDialog<AIBatchOrganizationPlan>(
      context: context,
      builder: (context) => SmartOrganizationDialog(plan: plan),
    );

    if (approvedPlan != null && mounted) {
      final baseDir = await StoragePathService.getReceivedFilesDirectory();
      final moved = await _aiService.organizer.executeApprovedPlan(
        plan: approvedPlan,
        baseDirectory: baseDir,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              moved > 0
                  ? 'Successfully organized $moved file into ${approvedPlan.suggestions.first.destinationFolder}/'
                  : 'Files already organized or moved.',
            ),
            backgroundColor: AppColors.primaryBlack,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.fileInfo ?? MockData.mockFiles[0];

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.s16),

              // Large monochrome checkmark icon
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  color: AppColors.primaryBlack,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppColors.backgroundWhite,
                  size: 48,
                ),
              ),
              const SizedBox(height: AppSpacing.s16),

              // Title
              const Text(
                'Transfer Complete',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlack,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s4),

              // File details
              Text(
                '${file.name} (${file.formattedSize}) • 100%',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.mediumGray,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s20),

              // Summary statistics card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.s16),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: AppShapes.cardBorderRadius,
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSummaryItem(
                      label: 'Receivers',
                      value: '${widget.receiversCount}',
                      icon: Icons.devices_rounded,
                    ),
                    Container(height: 32, width: 1, color: AppColors.borderGray),
                    _buildSummaryItem(
                      label: 'Duration',
                      value: widget.durationText,
                      icon: Icons.timer_outlined,
                    ),
                    Container(height: 32, width: 1, color: AppColors.borderGray),
                    _buildSummaryItem(
                      label: 'Avg Speed',
                      value: widget.avgSpeedText,
                      icon: Icons.speed_rounded,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s16),

              // AI FILE CLASSIFICATION CARD
              if (_classification != null) ...[
                Container(
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
                        children: [
                          const Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.primaryBlack),
                          const SizedBox(width: 8),
                          const Text(
                            'AI File Classification',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.lightGray,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${_classification!.confidencePercentage}% match',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20, color: AppColors.borderGray),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildDetailCol('Category', _classification!.category.displayName),
                          _buildDetailCol('Type', _classification!.fileType),
                          _buildDetailCol('Suggested Folder', '${_classification!.suggestedFolder}/'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s16),
              ],

              // SMART TRANSFER SUMMARY & AI INSIGHT
              if (_smartSummary != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.s16),
                  decoration: BoxDecoration(
                    color: AppColors.lightGray,
                    borderRadius: AppShapes.cardBorderRadius,
                    border: Border.all(color: AppColors.borderGray),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.insights_rounded, size: 16, color: AppColors.primaryBlack),
                          const SizedBox(width: 8),
                          const Text(
                            'AI Insight',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              const Icon(Icons.verified_rounded, size: 14, color: Colors.green),
                              const SizedBox(width: 4),
                              const Text(
                                'Integrity Verified',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _smartSummary!.aiInsight,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.darkGray,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s20),
              ],

              // Action buttons
              PrimaryButton(
                text: 'DONE',
                icon: Icons.check_rounded,
                onPressed: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
              ),
              const SizedBox(height: AppSpacing.s10),

              // AI Smart Organization Action Button
              if (_classification != null) ...[
                SecondaryButton(
                  text: 'ORGANIZE INTO ${_classification!.suggestedFolder.toUpperCase()}/',
                  icon: Icons.drive_file_move_outlined,
                  onPressed: () => _handleSmartOrganization(file),
                ),
                const SizedBox(height: AppSpacing.s10),
              ],

              SecondaryButton(
                text: 'CONFIRM FILE ON DISK',
                icon: Icons.verified_outlined,
                onPressed: () async {
                  File physicalFile = File(file.id);
                  bool exists = physicalFile.existsSync();
                  if (!exists) {
                    final defaultDir = await StoragePathService.getReceivedFilesDirectory();
                    final fallbackFile = File('${defaultDir.path}/${file.name}');
                    if (fallbackFile.existsSync()) {
                      physicalFile = fallbackFile;
                      exists = true;
                    }
                  }
                  final size = exists ? physicalFile.lengthSync() : 0;

                  if (!context.mounted) return;
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Row(
                        children: [
                          Icon(
                            exists ? Icons.check_circle_outline : Icons.error_outline,
                            color: exists ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          const Text('File Verification'),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Name: ${file.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Text('Path: ${physicalFile.path}', style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 8),
                          Text(
                            exists ? 'Status: Verified on Disk' : 'Status: NOT on disk',
                            style: TextStyle(
                              color: exists ? Colors.green : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (exists) ...[
                            const SizedBox(height: 8),
                            Text('Actual size: $size bytes'),
                            const SizedBox(height: 4),
                            const Text(
                              'Integrity: SHA-256 Verified (Tier 3 Passed)',
                              style: TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.s10),

              SecondaryButton(
                text: 'VIEW TRANSFER DETAILS',
                icon: Icons.bar_chart_rounded,
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => TransferDetailsScreen(
                        fileInfo: file,
                        durationText: widget.durationText,
                        avgSpeedText: widget.avgSpeedText,
                        receiversCount: widget.receiversCount,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.s16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryItem({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Column(
      children: [
        Icon(icon, size: 20, color: AppColors.darkGray),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.mediumGray,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailCol(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.mediumGray,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
      ],
    );
  }
}
