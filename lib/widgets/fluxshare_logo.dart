import 'package:flutter/material.dart';
import '../app/theme.dart';

class FluxShareLogo extends StatelessWidget {
  final double iconSize;
  final double fontSize;
  final bool showTagline;
  final String tagline;

  const FluxShareLogo({
    super.key,
    this.iconSize = 24.0,
    this.fontSize = 22.0,
    this.showTagline = false,
    this.tagline = 'Fast offline file sharing',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.s8),
              decoration: BoxDecoration(
                color: AppColors.primaryBlack,
                borderRadius: BorderRadius.circular(10.0),
              ),
              child: Icon(
                Icons.swap_horiz_rounded,
                color: AppColors.backgroundWhite,
                size: iconSize,
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            Text(
              'FluxShare',
              style: TextStyle(
                color: AppColors.primaryBlack,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        if (showTagline) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            tagline,
            style: const TextStyle(
              color: AppColors.mediumGray,
              fontSize: 14.0,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
