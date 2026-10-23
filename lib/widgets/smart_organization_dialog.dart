import 'package:flutter/material.dart';
import '../ai/ai_models.dart';
import '../app/theme.dart';

/// Modal dialog allowing the user to review, accept, or reject
/// AI-suggested folder organization for received files.
class SmartOrganizationDialog extends StatefulWidget {
  final AIBatchOrganizationPlan plan;

  const SmartOrganizationDialog({
    super.key,
    required this.plan,
  });

  @override
  State<SmartOrganizationDialog> createState() => _SmartOrganizationDialogState();
}

class _SmartOrganizationDialogState extends State<SmartOrganizationDialog> {
  late List<AIOrganizationSuggestion> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = widget.plan.suggestions;
  }

  @override
  Widget build(BuildContext context) {
    final acceptedCount = _suggestions.where((s) => s.isAccepted).length;

    return AlertDialog(
      backgroundColor: AppColors.backgroundWhite,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.cardBorderRadius,
        side: const BorderSide(color: AppColors.borderGray),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
              color: AppColors.primaryBlack,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.backgroundWhite,
              size: 16,
            ),
          ),
          const SizedBox(width: AppSpacing.s10),
          const Text(
            'Smart File Organization',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.plan.summary,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.darkGray,
                height: 1.35,
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            const Text(
              'Proposed Folders:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.mediumGray,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _suggestions.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s8),
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.lightGray,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderGray),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: suggestion.isAccepted,
                          activeColor: AppColors.primaryBlack,
                          onChanged: (val) {
                            setState(() {
                              suggestion.isAccepted = val ?? true;
                            });
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.folder_rounded, size: 16, color: AppColors.primaryBlack),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${suggestion.destinationFolder}/',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryBlack,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${suggestion.fileNames.length} file${suggestion.fileNames.length == 1 ? '' : 's'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.mediumGray,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                suggestion.fileNames.join(', '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.darkGray,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text(
            'REJECT',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColors.mediumGray,
            ),
          ),
        ),
        ElevatedButton(
          onPressed: acceptedCount > 0
              ? () => Navigator.of(context).pop(widget.plan)
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryBlack,
            foregroundColor: AppColors.backgroundWhite,
            shape: RoundedRectangleBorder(
              borderRadius: AppShapes.buttonBorderRadius,
            ),
          ),
          child: const Text(
            'ACCEPT & ORGANIZE',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
