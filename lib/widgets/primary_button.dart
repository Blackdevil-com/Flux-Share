import 'package:flutter/material.dart';
import '../app/theme.dart';

class PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isExpanded;
  final bool isLoading;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const PrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.isExpanded = true,
    this.isLoading = false,
    this.borderRadius = AppShapes.buttonRadius,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final bool isDisabled = onPressed == null || isLoading;

    final childContent = Row(
      mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading) ...[
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.backgroundWhite),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
        ] else if (icon != null) ...[
          Icon(
            icon,
            size: 20,
            color: isDisabled ? AppColors.mediumGray : AppColors.backgroundWhite,
          ),
          const SizedBox(width: AppSpacing.s8),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: isDisabled ? AppColors.mediumGray : AppColors.backgroundWhite,
          ),
        ),
      ],
    );

    final buttonStyle = ElevatedButton.styleFrom(
      backgroundColor: AppColors.primaryBlack,
      foregroundColor: AppColors.backgroundWhite,
      disabledBackgroundColor: AppColors.lightGray,
      disabledForegroundColor: AppColors.mediumGray,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: padding ??
          const EdgeInsets.symmetric(
            horizontal: AppSpacing.s20,
            vertical: AppSpacing.s16,
          ),
    );

    return isExpanded
        ? SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onPressed,
              style: buttonStyle,
              child: childContent,
            ),
          )
        : ElevatedButton(
            onPressed: onPressed,
            style: buttonStyle,
            child: childContent,
          );
  }
}
