import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../mock/mock_data.dart';
import '../../models/file_info.dart';
import '../../widgets/file_card.dart';

class MockFileBrowserScreen extends StatefulWidget {
  const MockFileBrowserScreen({super.key});

  @override
  State<MockFileBrowserScreen> createState() => _MockFileBrowserScreenState();
}

class _MockFileBrowserScreenState extends State<MockFileBrowserScreen> {
  FileType? _selectedFilter;

  List<FileInfo> get _filteredFiles {
    if (_selectedFilter == null) {
      return MockData.mockFiles;
    }
    return MockData.mockFiles.where((f) => f.type == _selectedFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Browse Storage'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s16,
              vertical: AppSpacing.s12,
            ),
            child: Row(
              children: [
                _buildFilterChip('All Files', null),
                const SizedBox(width: AppSpacing.s8),
                _buildFilterChip('Videos', FileType.Video),
                const SizedBox(width: AppSpacing.s8),
                _buildFilterChip('Documents', FileType.Document),
                const SizedBox(width: AppSpacing.s8),
                _buildFilterChip('Archives', FileType.Archive),
                const SizedBox(width: AppSpacing.s8),
                _buildFilterChip('Presentations', FileType.Presentation),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _filteredFiles.isEmpty
                ? const Center(
                    child: Text(
                      'No files found',
                      style: TextStyle(color: AppColors.mediumGray),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.s16),
                    itemCount: _filteredFiles.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s12),
                    itemBuilder: (context, index) {
                      final file = _filteredFiles[index];
                      return FileCard(
                        fileInfo: file,
                        onTap: () {
                          Navigator.of(context).pop(file);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, FileType? type) {
    final isSelected = _selectedFilter == type;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedFilter = selected ? type : null;
        });
      },
      selectedColor: AppColors.primaryBlack,
      backgroundColor: AppColors.lightGray,
      labelStyle: TextStyle(
        color: isSelected ? AppColors.backgroundWhite : AppColors.primaryBlack,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 13,
      ),
      side: BorderSide(
        color: isSelected ? AppColors.primaryBlack : AppColors.borderGray,
      ),
      showCheckmark: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.0),
      ),
    );
  }
}
