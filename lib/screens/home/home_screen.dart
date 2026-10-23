import 'package:flutter/material.dart';
import '../../ai/ai_service.dart';
import '../../app/theme.dart';
import '../../models/models.dart';
import '../../repositories/device_repository.dart';
import '../../repositories/transfer_repository.dart';
import '../../widgets/widgets.dart';
import '../ai_assistant/ai_assistant_screen.dart';
import '../nearby_devices/nearby_devices_screen.dart';
import '../receive_file/receive_file_screen.dart';
import '../send_file/send_file_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onNavigateToTransfers;
  final VoidCallback? onNavigateToHistory;

  const HomeScreen({
    super.key,
    this.onNavigateToTransfers,
    this.onNavigateToHistory,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DeviceRepository _deviceRepository = DeviceRepository();
  final TransferRepository _transferRepository = TransferRepository();

  List<Device> _nearbyDevices = [];
  List<Transfer> _recentTransfers = [];
  bool _isLoadingDevices = true;
  bool _isLoadingTransfers = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    _loadNearbyDevices();
    _loadRecentTransfers();
  }

  Future<void> _loadNearbyDevices() async {
    final devices = await _deviceRepository.getNearbyDevices();
    if (mounted) {
      setState(() {
        _nearbyDevices = devices;
        _isLoadingDevices = false;
      });
    }
  }

  Future<void> _loadRecentTransfers() async {
    final active = await _transferRepository.getActiveTransfers();
    final history = await _transferRepository.getTransferHistory();
    if (mounted) {
      setState(() {
        _recentTransfers = [...active, ...history].take(3).toList();
        _isLoadingTransfers = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: AppColors.primaryBlack,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.s8),
                const FluxShareLogo(
                  showTagline: true,
                  tagline: 'Fast offline file sharing',
                ),
                const SizedBox(height: AppSpacing.s24),
                _buildActionButtons(),
                const SizedBox(height: AppSpacing.s24),
                _buildAIAssistantBanner(),
                const SizedBox(height: AppSpacing.s24),
                _buildNetworkStatusCard(),
                const SizedBox(height: AppSpacing.s24),
                _buildNearbyDevicesSection(),
                const SizedBox(height: AppSpacing.s24),
                _buildRecentTransfersSection(),
                const SizedBox(height: AppSpacing.s16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: PrimaryButton(
            text: 'SEND FILE',
            icon: Icons.arrow_upward_rounded,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const SendFileScreen(),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: SecondaryButton(
            text: 'RECEIVE FILE',
            icon: Icons.arrow_downward_rounded,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ReceiveFileScreen(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNetworkStatusCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.lightGray,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.borderGray),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.s8),
            decoration: const BoxDecoration(
              color: AppColors.primaryBlack,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.wifi_rounded,
              color: AppColors.backgroundWhite,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NETWORK STATUS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: AppColors.darkGray,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Wi-Fi • Connected • Local network active',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlack,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.primaryBlack,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNearbyDevicesSection() {
    final displayDevices = _nearbyDevices.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Nearby Devices',
          actionText: 'See all >',
          onActionTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const NearbyDevicesScreen(),
              ),
            );
          },
        ),
        if (_isLoadingDevices)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primaryBlack),
            ),
          )
        else if (displayDevices.isEmpty)
          Container(
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
                  Icons.devices_other_rounded,
                  color: AppColors.mediumGray,
                  size: 32,
                ),
                SizedBox(height: AppSpacing.s8),
                Text(
                  'No nearby devices detected',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBlack,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Connect devices to the same Wi-Fi network',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mediumGray,
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            children: displayDevices.map((device) {
              return DeviceListItem(
                device: device,
                isCompact: true,
                onTap: () {
                  if (device.isAvailable) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => SendFileScreen(
                          initialDeviceId: device.id,
                        ),
                      ),
                    );
                  }
                },
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildRecentTransfersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Recent Transfers',
          actionText: 'See all >',
          onActionTap: () {
            if (widget.onNavigateToHistory != null) {
              widget.onNavigateToHistory!();
            } else if (widget.onNavigateToTransfers != null) {
              widget.onNavigateToTransfers!();
            }
          },
        ),
        if (_isLoadingTransfers)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primaryBlack),
            ),
          )
        else if (_recentTransfers.isEmpty)
          Container(
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
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBlack,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Send or receive files to see transfer cards here',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mediumGray,
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            children: _recentTransfers.map((transfer) {
              return Container(
                margin: const EdgeInsets.only(bottom: AppSpacing.s8),
                padding: const EdgeInsets.all(AppSpacing.s12),
                decoration: BoxDecoration(
                  color: AppColors.backgroundWhite,
                  borderRadius: AppShapes.cardBorderRadius,
                  border: Border.all(color: AppColors.borderGray),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: AppColors.lightGray,
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      child: Icon(
                        transfer.direction == TransferDirection.sent
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
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlack,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${transfer.fileInfo.formattedSize} • ${transfer.status.name}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.mediumGray,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    if (transfer.status == TransferStatus.transferring)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          value: transfer.progressPercent / 100.0,
                          strokeWidth: 2.5,
                          color: AppColors.primaryBlack,
                          backgroundColor: AppColors.lightGray,
                        ),
                      )
                    else
                      Icon(
                        transfer.status == TransferStatus.completed
                            ? Icons.check_circle_rounded
                            : Icons.info_outline_rounded,
                        color: transfer.status == TransferStatus.completed
                            ? AppColors.primaryBlack
                            : AppColors.mediumGray,
                        size: 20,
                      ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildAIAssistantBanner() {
    final aiService = AIService();
    final isEnabled = aiService.config.isAiEnabled;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: AppColors.backgroundWhite,
        borderRadius: AppShapes.cardBorderRadius,
        border: Border.all(color: AppColors.primaryBlack, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
              const SizedBox(width: AppSpacing.s8),
              const Text(
                'AI Assistant',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlack,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: isEnabled ? Colors.green : AppColors.mediumGray,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isEnabled ? 'Enabled' : 'Disabled',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkGray,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          const Text(
            'Ask FLUXSHARE anything...',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.mediumGray,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildAssistantQuickChip('Why is my transfer slow?'),
              _buildAssistantQuickChip('Analyze recent transfers'),
              _buildAssistantQuickChip('Find large files'),
              _buildAssistantQuickChip('Optimize transfer'),
            ],
          ),
          const SizedBox(height: AppSpacing.s12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AIAssistantScreen()),
                );
              },
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16, color: AppColors.primaryBlack),
              label: const Text(
                'OPEN ASSISTANT',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primaryBlack),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primaryBlack),
                shape: RoundedRectangleBorder(borderRadius: AppShapes.buttonBorderRadius),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantQuickChip(String label) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AIAssistantScreen()),
        );
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.lightGray,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderGray),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.primaryBlack,
          ),
        ),
      ),
    );
  }
}

