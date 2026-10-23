import 'package:flutter/material.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../../models/models.dart';
import '../../repositories/transfer_repository.dart';
import '../transfer/transfer_details_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TransferRepository _repository = TransferRepository();
  final TextEditingController _searchController = TextEditingController();
  List<Transfer> _allHistory = [];
  String _selectedFilter = 'All'; // 'All', 'Completed', 'Failed', 'Cancelled'
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final list = await _repository.getTransferHistory();
    if (mounted) {
      setState(() {
        _allHistory = list;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Transfer> get _filteredTransfers {
    List<Transfer> base;
    switch (_selectedFilter) {
      case 'Completed':
        base = _allHistory
            .where((t) => t.status == TransferStatus.completed)
            .toList();
        break;
      case 'Failed':
        base = _allHistory
            .where((t) => t.status == TransferStatus.failed)
            .toList();
        break;
      case 'Cancelled':
        base = _allHistory
            .where((t) => t.status == TransferStatus.cancelled)
            .toList();
        break;
      case 'All':
      default:
        base = _allHistory;
        break;
    }

    if (_searchQuery.trim().isNotEmpty && AIService().config.isAiEnabled) {
      return AIService().smartSearch.searchTransfers(
        query: _searchQuery,
        transfers: base,
      );
    }

    return base;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTransfers;

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Transfer History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadHistory();
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          const SizedBox(height: AppSpacing.s8),
          _buildFilterBar(),
          const SizedBox(height: AppSpacing.s8),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primaryBlack,
                    ),
                  )
                : filtered.isEmpty
                    ? _buildEmptyStateForFilter()
                    : ListView.separated(
                        padding: const EdgeInsets.all(AppSpacing.s16),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.s12),
                        itemBuilder: (context, index) {
                          final transfer = filtered[index];
                          return _buildHistoryItem(transfer);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final filters = ['All', 'Completed', 'Failed', 'Cancelled'];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
      child: Row(
        children: filters.map((filter) {
          final isSelected = _selectedFilter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s8),
            child: ChoiceChip(
              label: Text(
                filter,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? AppColors.backgroundWhite
                      : AppColors.primaryBlack,
                ),
              ),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) {
                  setState(() => _selectedFilter = filter);
                }
              },
              selectedColor: AppColors.primaryBlack,
              backgroundColor: AppColors.lightGray,
              side: BorderSide(
                color: isSelected ? AppColors.primaryBlack : AppColors.borderGray,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20.0),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s12,
                vertical: AppSpacing.s8,
              ),
              showCheckmark: false,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmptyStateForFilter() {
    String title;
    String subtitle;

    switch (_selectedFilter) {
      case 'Completed':
        title = 'No completed transfers';
        subtitle = 'Completed transfers will appear here.';
        break;
      case 'Failed':
        title = 'No failed transfers';
        subtitle = 'Failed transfer attempts will appear here.';
        break;
      case 'Cancelled':
        title = 'No cancelled transfers';
        subtitle = 'Cancelled transfer tasks will appear here.';
        break;
      case 'All':
      default:
        title = 'No transfer history';
        subtitle = 'Past file transfers will be recorded here.';
        break;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.lightGray,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.history_rounded,
                size: 32,
                color: AppColors.darkGray,
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlack,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
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
    );
  }

  Widget _buildHistoryItem(Transfer transfer) {
    final isSent = transfer.direction == TransferDirection.sent;
    final isCompleted = transfer.status == TransferStatus.completed;

    IconData statusIcon;
    if (isCompleted) {
      statusIcon = Icons.check_circle_rounded;
    } else {
      statusIcon = Icons.cancel_rounded;
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => TransferDetailsScreen(
              fileInfo: transfer.fileInfo,
            ),
          ),
        );
      },
      borderRadius: AppShapes.cardBorderRadius,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s16),
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: AppShapes.cardBorderRadius,
          border: Border.all(color: AppColors.borderGray),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10.0),
              decoration: BoxDecoration(
                color: AppColors.lightGray,
                borderRadius: BorderRadius.circular(10.0),
              ),
              child: Icon(
                isSent ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                color: AppColors.primaryBlack,
                size: 20,
              ),
            ),
            const SizedBox(width: AppSpacing.s16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    transfer.fileInfo.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryBlack,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${isSent ? "Sent" : "Received"} • ${transfer.fileInfo.formattedSize}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.mediumGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatTimestamp(transfer.timestamp),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.mediumGray,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(
                  statusIcon,
                  color: isCompleted ? AppColors.primaryBlack : AppColors.darkGray,
                  size: 20,
                ),
                const SizedBox(height: 4),
                Text(
                  isCompleted
                      ? 'Completed'
                      : transfer.status == TransferStatus.failed
                          ? 'Failed'
                          : 'Cancelled',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isCompleted ? AppColors.primaryBlack : AppColors.darkGray,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final itemDate = DateTime(dt.year, dt.month, dt.day);

    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$minute $period';

    if (itemDate == today) {
      return 'Today, $timeStr';
    } else if (itemDate == yesterday) {
      return 'Yesterday, $timeStr';
    } else {
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[dt.month - 1]} ${dt.day}, $timeStr';
    }
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16, vertical: AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            onChanged: (val) {
              setState(() {
                _searchQuery = val;
              });
            },
            decoration: InputDecoration(
              hintText: 'Search: "videos today", "> 500 MB", "Akash"...',
              hintStyle: const TextStyle(fontSize: 13, color: AppColors.mediumGray),
              prefixIcon: const Icon(Icons.search_rounded, size: 20, color: AppColors.primaryBlack),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18, color: AppColors.mediumGray),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.lightGray,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.borderGray),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.borderGray),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.primaryBlack),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildSearchFilterChip('Videos today'),
                const SizedBox(width: 6),
                _buildSearchFilterChip('> 500 MB'),
                const SizedBox(width: 6),
                _buildSearchFilterChip('PDFs this week'),
                const SizedBox(width: 6),
                _buildSearchFilterChip('Largest files'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchFilterChip(String query) {
    final isSelected = _searchQuery.toLowerCase() == query.toLowerCase();
    return ActionChip(
      backgroundColor: isSelected ? AppColors.primaryBlack : AppColors.backgroundWhite,
      side: const BorderSide(color: AppColors.borderGray),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      label: Text(
        query,
        style: TextStyle(
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? AppColors.backgroundWhite : AppColors.primaryBlack,
        ),
      ),
      onPressed: () {
        setState(() {
          _searchController.text = query;
          _searchQuery = query;
        });
      },
    );
  }
}
