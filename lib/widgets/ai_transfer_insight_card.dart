import 'package:flutter/material.dart';
import '../ai/ai_models.dart';
import '../app/theme.dart';

/// Card displayed on the Transfer Progress screen providing live diagnosis,
/// recommendations, and an approval button before applying networking parameter updates.
class AITransferInsightCard extends StatelessWidget {
  final AITransferOptimization? optimization;
  final AIFailureDiagnosis? diagnosis;
  final VoidCallback? onApplyRecommendation;
  final bool isApplied;

  const AITransferInsightCard({
    super.key,
    this.optimization,
    this.diagnosis,
    this.onApplyRecommendation,
    this.isApplied = false,
  });

  @override
  Widget build(BuildContext context) {
    if (optimization == null && diagnosis == null) {
      return const SizedBox.shrink();
    }

    final hasIssue = diagnosis != null && diagnosis!.issueDetected;
    final title = hasIssue ? 'AI Transfer Warning' : 'AI Transfer Insight';
    final statusText = hasIssue
        ? diagnosis!.severity.displayName
        : (optimization != null && optimization!.useParallel ? 'Optimal Link' : 'Moderate Link');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.s12),
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(
          color: hasIssue ? AppColors.primaryBlack : AppColors.borderGray,
          width: hasIssue ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: hasIssue ? AppColors.primaryBlack : AppColors.lightGray,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  hasIssue ? Icons.warning_amber_rounded : Icons.auto_awesome_rounded,
                  size: 16,
                  color: hasIssue ? AppColors.backgroundWhite : AppColors.primaryBlack,
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlack,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: hasIssue ? AppColors.lightGray : AppColors.lightGray,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Text(
                  statusText,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlack,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.s12),

          // Diagnostic explanation
          if (diagnosis != null && diagnosis!.issueDetected) ...[
            Text(
              diagnosis!.explanation,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.primaryBlack,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
          ],

          // Recommendation details
          if (optimization != null) ...[
            const Text(
              'Recommendation:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.mediumGray,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Set workers to ${optimization!.recommendedParallelWorkers} parallel streams with ${optimization!.recommendedChunkSizeLabel} chunks.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryBlack,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),

            const Text(
              'Reason:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppColors.mediumGray,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              optimization!.reason,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.darkGray,
                height: 1.35,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),

            // User Approval Action Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isApplied ? null : onApplyRecommendation,
                icon: Icon(
                  isApplied ? Icons.check_circle_rounded : Icons.tune_rounded,
                  size: 16,
                  color: isApplied ? Colors.green : AppColors.primaryBlack,
                ),
                label: Text(
                  isApplied ? 'Recommendation Applied' : 'Apply Recommendation',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isApplied ? Colors.green : AppColors.primaryBlack,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  side: BorderSide(
                    color: isApplied ? Colors.green : AppColors.primaryBlack,
                    width: 1.2,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: AppShapes.buttonBorderRadius,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
