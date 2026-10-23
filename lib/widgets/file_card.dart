import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../models/file_info.dart';

class FileCard extends StatelessWidget {
  final FileInfo fileInfo;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool isSelected;

  const FileCard({
    super.key,
    required this.fileInfo,
    this.onRemove,
    this.onTap,
    this.isSelected = false,
  });

  IconData _getFileIcon(FileType type) {
    switch (type) {
      case FileType.Video:
        return Icons.movie_outlined;
      case FileType.Document:
        return Icons.description_outlined;
      case FileType.Archive:
        return Icons.folder_zip_outlined;
      case FileType.Presentation:
        return Icons.slideshow_outlined;
      case FileType.Image:
        return Icons.image_outlined;
      case FileType.Other:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? AppColors.lightGray : AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(
          color: isSelected ? AppColors.primaryBlack : AppColors.borderGray,
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.cardBorderRadius,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(12.0),
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Icon(
                  _getFileIcon(fileInfo.type),
                  color: AppColors.primaryBlack,
                  size: 24,
                ),
              ),
              const SizedBox(width: AppSpacing.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileInfo.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryBlack,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${fileInfo.formattedSize} • ${fileInfo.extension.toUpperCase()}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.mediumGray,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: AppSpacing.s8),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded),
                  color: AppColors.darkGray,
                  tooltip: 'Remove file',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FilePickerCard extends StatelessWidget {
  final VoidCallback onTap;
  final String title;
  final String subtitle;

  const FilePickerCard({
    super.key,
    required this.onTap,
    this.title = 'Tap to select a file',
    this.subtitle = 'Browse your storage',
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.cardBorderRadius,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s24,
            vertical: AppSpacing.s32,
          ),
          decoration: BoxDecoration(
            color: AppColors.lightGray.withOpacity(0.5),
            borderRadius: AppShapes.cardBorderRadius,
            border: Border.all(
              color: AppColors.primaryBlack,
              width: 1.2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: AppColors.primaryBlack,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.upload_file_rounded,
                  color: AppColors.backgroundWhite,
                  size: 28,
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlack,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.mediumGray,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
