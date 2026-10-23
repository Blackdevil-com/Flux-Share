import 'package:flutter/material.dart';
import '../app/theme.dart';

class SecondaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isExpanded;
  final bool isLoading;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const SecondaryButton({
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
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryBlack),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
        ] else if (icon != null) ...[
          Icon(
            icon,
            size: 20,
            color: isDisabled ? AppColors.mediumGray : AppColors.primaryBlack,
          ),
          const SizedBox(width: AppSpacing.s8),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: isDisabled ? AppColors.mediumGray : AppColors.primaryBlack,
          ),
        ),
      ],
    );

    final buttonStyle = OutlinedButton.styleFrom(
      backgroundColor: AppColors.backgroundWhite,
      foregroundColor: AppColors.primaryBlack,
      disabledBackgroundColor: AppColors.lightGray,
      disabledForegroundColor: AppColors.mediumGray,
      side: BorderSide(
        color: isDisabled ? AppColors.borderGray : AppColors.primaryBlack,
        width: 1.2,
      ),
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
            child: OutlinedButton(
              onPressed: onPressed,
              style: buttonStyle,
              child: childContent,
            ),
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: buttonStyle,
            child: childContent,
          );
  }
}
