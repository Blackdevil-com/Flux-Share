import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../models/models.dart';
import '../../repositories/transfer_repository.dart';
import '../../widgets/widgets.dart';
import '../transfer/transfer_details_screen.dart';

class TransfersScreen extends StatefulWidget {
  const TransfersScreen({super.key});

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  final TransferRepository _repository = TransferRepository();
  List<Transfer> _activeTransfers = [];
  List<Transfer> _recentTransfers = [];
  bool _isLoading = true;
  final List<StreamSubscription<Transfer>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _loadTransfers();
  }

  @override
  void dispose() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _loadTransfers() async {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    final active = await _repository.getActiveTransfers();
    final history = await _repository.getTransferHistory();

    if (mounted) {
      setState(() {
        _activeTransfers = active;
        _recentTransfers = history;
        _isLoading = false;
      });

      // Subscribe to progress stream for active transferring items
      for (var t in active) {
        if (t.status == TransferStatus.transferring) {
          final sub = _repository.simulateTransferProgress(t.id).listen((updated) {
            if (mounted) {
              _onTransferUpdated(updated);
            }
          });
          _subscriptions.add(sub);
        }
      }
    }
  }

  void _onTransferUpdated(Transfer updated) {
    setState(() {
      final index = _activeTransfers.indexWhere((t) => t.id == updated.id);
      if (index != -1) {
        if (updated.status == TransferStatus.completed ||
            updated.status == TransferStatus.failed ||
            updated.status == TransferStatus.cancelled) {
          _activeTransfers.removeAt(index);
          _recentTransfers.insert(0, updated);
        } else {
          _activeTransfers[index] = updated;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadTransfers();
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryBlack),
            )
          : RefreshIndicator(
              onRefresh: _loadTransfers,
              color: AppColors.primaryBlack,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.s16),
                children: [
                  // ACTIVE TRANSFERS Section
                  const SectionHeader(title: 'ACTIVE TRANSFERS'),
                  if (_activeTransfers.isEmpty)
                    _buildActiveEmptyState()
                  else
                    Column(
                      children: _activeTransfers
                          .map((t) => _buildActiveTransferItem(t))
                          .toList(),
                    ),

                  const SizedBox(height: AppSpacing.s24),

                  // RECENT TRANSFERS Section
                  const SectionHeader(title: 'RECENT TRANSFERS'),
                  if (_recentTransfers.isEmpty)
                    _buildRecentEmptyState()
                  else
                    Column(
                      children: _recentTransfers
                          .map((t) => _buildRecentTransferItem(t))
                          .toList(),
                    ),
                  const SizedBox(height: AppSpacing.s16),
                ],
              ),
            ),
    );
  }

  Widget _buildActiveEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s20),
      decoration: BoxDecoration(
        color: AppColors.lightGray.withOpacity(0.5),
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.swap_vert_rounded,
            color: AppColors.mediumGray,
            size: 32,
          ),
          SizedBox(height: AppSpacing.s8),
          Text(
            'No active transfers',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Ongoing file transfers will appear here in real-time.',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.mediumGray,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRecentEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s20),
      decoration: BoxDecoration(
        color: AppColors.lightGray.withOpacity(0.5),
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.history_rounded,
            color: AppColors.mediumGray,
            size: 32,
          ),
          SizedBox(height: AppSpacing.s8),
          Text(
            'No recent transfers',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Completed file transfers will appear here.',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.mediumGray,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTransferItem(Transfer transfer) {
    final isSent = transfer.direction == TransferDirection.sent;
    final progressInt = transfer.progressPercent.toInt();
    final directionText = isSent ? "Sending" : "Receiving";

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s12),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: InkWell(
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
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: AppColors.lightGray,
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: Icon(
                      isSent
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      color: AppColors.primaryBlack,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s12),
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
                        const SizedBox(height: 2),
                        Text(
                          '$directionText $progressInt% • ${transfer.fileInfo.formattedSize}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.mediumGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: transfer.status == TransferStatus.transferring
                          ? AppColors.primaryBlack
                          : AppColors.lightGray,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      transfer.status.name.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: transfer.status == TransferStatus.transferring
                            ? AppColors.backgroundWhite
                            : AppColors.primaryBlack,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4.0),
                child: LinearProgressIndicator(
                  value: transfer.progressPercent / 100.0,
                  backgroundColor: AppColors.lightGray,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.primaryBlack),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: AppSpacing.s12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$progressInt% (${transfer.transferSpeedMbPerSec.toStringAsFixed(1)} MB/s)',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  if (transfer.status == TransferStatus.transferring)
                    InkWell(
                      onTap: () async {
                        await _repository.pauseTransfer(transfer.id);
                        _loadTransfers();
                      },
                      child: const Text(
                        'Pause',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGray,
                        ),
                      ),
                    )
                  else if (transfer.status == TransferStatus.paused)
                    InkWell(
                      onTap: () async {
                        await _repository.resumeTransfer(transfer.id);
                        _loadTransfers();
                      },
                      child: const Text(
                        'Resume',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlack,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentTransferItem(Transfer transfer) {
    final isSent = transfer.direction == TransferDirection.sent;
    final isCompleted = transfer.status == TransferStatus.completed;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s12),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: InkWell(
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
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10.0),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(10.0),
                ),
                child: Icon(
                  isSent
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
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
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(
                    isCompleted
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                    color: isCompleted
                        ? AppColors.primaryBlack
                        : AppColors.mediumGray,
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
                      color: isCompleted
                          ? AppColors.primaryBlack
                          : AppColors.mediumGray,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
