import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../models/device.dart';

class DeviceListItem extends StatelessWidget {
  final Device device;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectedChanged;
  final VoidCallback? onTap;
  final bool isCompact;

  const DeviceListItem({
    super.key,
    required this.device,
    this.isSelected = false,
    this.onSelectedChanged,
    this.onTap,
    this.isCompact = false,
  });

  IconData _getPlatformIcon(DevicePlatform platform) {
    switch (platform) {
      case DevicePlatform.iPhone:
        return Icons.phone_iphone_rounded;
      case DevicePlatform.Android:
        return Icons.phone_android_rounded;
      case DevicePlatform.Windows:
        return Icons.laptop_rounded;
    }
  }

  Widget _buildSignalIndicator(int signalStrength) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final isActive = index < signalStrength;
        return Container(
          margin: const EdgeInsets.only(right: 2.0),
          width: 3.5,
          height: 6.0 + (index * 3.0),
          decoration: BoxDecoration(
            color: isActive ? AppColors.primaryBlack : AppColors.borderGray,
            borderRadius: BorderRadius.circular(1.0),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: isCompact ? AppSpacing.s8 : AppSpacing.s12),
      decoration: BoxDecoration(
        color: isSelected ? AppColors.lightGray : AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(
          color: isSelected ? AppColors.primaryBlack : AppColors.borderGray,
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: onTap ??
            (onSelectedChanged != null && device.isAvailable
                ? () => onSelectedChanged!(!isSelected)
                : null),
        borderRadius: AppShapes.cardBorderRadius,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.s16,
            vertical: isCompact ? AppSpacing.s12 : AppSpacing.s16,
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(10.0),
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Icon(
                  _getPlatformIcon(device.platform),
                  color: AppColors.primaryBlack,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryBlack,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          device.platform.displayName,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.mediumGray,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          '•',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.mediumGray,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          device.isAvailable ? 'Available' : 'Busy',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: device.isAvailable
                                ? AppColors.primaryBlack
                                : AppColors.mediumGray,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              _buildSignalIndicator(device.signalStrength),
              if (onSelectedChanged != null) ...[
                const SizedBox(width: AppSpacing.s12),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: isSelected,
                    onChanged: device.isAvailable ? onSelectedChanged : null,
                    activeColor: AppColors.primaryBlack,
                    checkColor: AppColors.backgroundWhite,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    side: const BorderSide(color: AppColors.darkGray, width: 1.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
