import 'package:flutter/material.dart';
import '../../ai/ai_config.dart';
import '../../app/theme.dart';
import '../../models/app_settings.dart';
import '../../widgets/widgets.dart';
import '../about/about_screen.dart';
import '../history/history_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AIConfig _aiConfig = AIConfig();
  final AppSettings _settings = AppSettings();
  late String _deviceName;
  late bool _autoAccept;
  late double _maxParallelConnections;
  late bool _showNotifications;
  late String _storageLocation;

  @override
  void initState() {
    super.initState();
    _deviceName = _settings.deviceName;
    _autoAccept = _settings.autoAccept;
    _maxParallelConnections = _settings.maxParallelConnections.toDouble();
    _showNotifications = _settings.showNotifications;
    _storageLocation = _settings.customDownloadPath.isNotEmpty
        ? _settings.customDownloadPath
        : 'App Documents/FluxShare';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.s16),
        children: [
          // DEVICE section
          const SectionHeader(title: 'DEVICE'),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s16),
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: AppShapes.cardBorderRadius,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: InkWell(
              onTap: _showEditDeviceNameDialog,
              borderRadius: AppShapes.cardBorderRadius,
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryBlack,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.phone_android_rounded,
                      color: AppColors.backgroundWhite,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Device Name',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.mediumGray,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _deviceName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlack,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.edit_rounded,
                    color: AppColors.primaryBlack,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s24),

          // TRANSFER section
          const SectionHeader(title: 'TRANSFER'),
          Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: AppShapes.cardBorderRadius,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  value: _autoAccept,
                  onChanged: (val) async {
                    await _settings.setAutoAccept(val);
                    setState(() => _autoAccept = val);
                  },
                  title: const Text(
                    'Auto Accept Transfers',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  subtitle: const Text(
                    'Automatically accept file transfers from nearby devices',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.mediumGray,
                    ),
                  ),
                  activeColor: AppColors.primaryBlack,
                ),
                const Divider(height: 1, color: AppColors.borderGray),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s16,
                    vertical: AppSpacing.s12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Maximum Parallel Connections',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryBlack,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.lightGray,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_maxParallelConnections.toInt()}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primaryBlack,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Limit concurrent peer socket connections (1 to 10)',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.mediumGray,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppColors.primaryBlack,
                          inactiveTrackColor: AppColors.borderGray,
                          thumbColor: AppColors.primaryBlack,
                          overlayColor: AppColors.primaryBlack.withOpacity(0.12),
                          valueIndicatorColor: AppColors.primaryBlack,
                          valueIndicatorTextStyle: const TextStyle(
                            color: AppColors.backgroundWhite,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        child: Slider(
                          value: _maxParallelConnections,
                          min: 1.0,
                          max: 10.0,
                          divisions: 9,
                          label: '${_maxParallelConnections.toInt()}',
                          onChanged: (val) async {
                            await _settings.setMaxParallelConnections(val.toInt());
                            setState(() => _maxParallelConnections = val);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.borderGray),
                SwitchListTile(
                  value: _showNotifications,
                  onChanged: (val) async {
                    await _settings.setShowNotifications(val);
                    setState(() => _showNotifications = val);
                  },
                  title: const Text(
                    'Show Transfer Notifications',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  subtitle: const Text(
                    'Receive progress notifications during file transfers',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.mediumGray,
                    ),
                  ),
                  activeColor: AppColors.primaryBlack,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s24),

          // STORAGE section
          const SectionHeader(title: 'STORAGE'),
          Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: AppShapes.cardBorderRadius,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: ListTile(
              onTap: _showStorageLocationDialog,
              leading: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: const Icon(
                  Icons.folder_outlined,
                  color: AppColors.primaryBlack,
                  size: 20,
                ),
              ),
              title: const Text(
                'Storage Location',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBlack,
                ),
              ),
              subtitle: Text(
                _storageLocation,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.mediumGray,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.darkGray,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s24),

          // AI & PRIVACY section
          _buildAiPrivacySection(),

          // HISTORY section
          const SectionHeader(title: 'HISTORY'),
          Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: AppShapes.cardBorderRadius,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: ListTile(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const HistoryScreen(),
                  ),
                );
              },
              leading: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: const Icon(
                  Icons.history_rounded,
                  color: AppColors.primaryBlack,
                  size: 20,
                ),
              ),
              title: const Text(
                'Transfer History',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBlack,
                ),
              ),
              subtitle: const Text(
                'View logs of past transfers',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.mediumGray,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.darkGray,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s24),

          // ABOUT section
          const SectionHeader(title: 'ABOUT'),
          Container(
            decoration: BoxDecoration(
              color: AppColors.backgroundWhite,
              borderRadius: AppShapes.cardBorderRadius,
              border: Border.all(color: AppColors.borderGray),
            ),
            child: ListTile(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const AboutScreen(),
                  ),
                );
              },
              leading: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: AppColors.lightGray,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: AppColors.primaryBlack,
                  size: 20,
                ),
              ),
              title: const Text(
                'About',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBlack,
                ),
              ),
              subtitle: const Text(
                'Version 1.0.0, licenses and info',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.mediumGray,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.darkGray,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s24),
        ],
      ),
    );
  }

  void _showEditDeviceNameDialog() {
    final controller = TextEditingController(text: _deviceName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.backgroundWhite,
          shape: AppShapes.cardShape,
          title: const Text(
            'Edit Device Name',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryBlack,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Enter new device name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final trimmed = controller.text.trim();
                if (trimmed.isNotEmpty) {
                  setState(() {
                    _deviceName = trimmed;
                  });
                }
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showStorageLocationDialog() {
    final List<String> mockLocations = [
      '/storage/emulated/0/FluxShare',
      '/storage/emulated/0/Download/FluxShare',
      '/storage/emulated/0/Documents/FluxShare',
    ];

    String selectedTemp = _storageLocation;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.backgroundWhite,
              shape: AppShapes.cardShape,
              title: const Text(
                'Select Storage Location',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlack,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: mockLocations.map((loc) {
                  final isSelected = loc == selectedTemp;
                  return RadioListTile<String>(
                    value: loc,
                    groupValue: selectedTemp,
                    activeColor: AppColors.primaryBlack,
                    title: Text(
                      loc,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedTemp = val);
                      }
                    },
                  );
                }).toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _storageLocation = selectedTemp;
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Select'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildAiPrivacySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'AI & PRIVACY'),
        Container(
          decoration: BoxDecoration(
            color: AppColors.backgroundWhite,
            borderRadius: AppShapes.cardBorderRadius,
            border: Border.all(color: AppColors.borderGray),
          ),
          child: Column(
            children: [
              SwitchListTile(
                value: _aiConfig.isAiEnabled,
                onChanged: (val) async {
                  await _aiConfig.setAiEnabled(val);
                  setState(() {});
                },
                title: const Text(
                  'AI Assistance',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBlack,
                  ),
                ),
                subtitle: const Text(
                  'Enable transfer optimization, failure detection & smart organization',
                  style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
                ),
                activeColor: AppColors.primaryBlack,
              ),
              if (_aiConfig.isAiEnabled) ...[
                const Divider(height: 1, color: AppColors.borderGray),
                SwitchListTile(
                  value: _aiConfig.allowCloudAi,
                  onChanged: (val) async {
                    await _aiConfig.setAllowCloudAi(val);
                    setState(() {});
                  },
                  title: const Text(
                    'Allow Cloud AI (Google Gemini)',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  subtitle: Text(
                    _aiConfig.allowCloudAi
                        ? 'Cloud analysis enabled. Only metadata is analyzed; private files are never uploaded.'
                        : 'Privacy First: Off = 100% offline local rule engine.',
                    style: const TextStyle(fontSize: 13, color: AppColors.mediumGray),
                  ),
                  activeColor: AppColors.primaryBlack,
                ),
                if (_aiConfig.allowCloudAi) ...[
                  const Divider(height: 1, color: AppColors.borderGray),
                  ListTile(
                    onTap: _showApiKeyDialog,
                    leading: const Icon(Icons.key_rounded, color: AppColors.primaryBlack, size: 20),
                    title: const Text(
                      'Gemini API Key',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryBlack,
                      ),
                    ),
                    subtitle: Text(
                      _aiConfig.hasValidApiKey ? '••••••••••••••••' : 'Not configured (tap to set)',
                      style: TextStyle(
                        fontSize: 13,
                        color: _aiConfig.hasValidApiKey ? AppColors.darkGray : Colors.red,
                      ),
                    ),
                    trailing: const Icon(Icons.edit_rounded, size: 18, color: AppColors.primaryBlack),
                  ),
                ],
                const Divider(height: 1, color: AppColors.borderGray),
                SwitchListTile(
                  value: _aiConfig.autoSuggestOrganization,
                  onChanged: (val) async {
                    await _aiConfig.setAutoSuggestOrganization(val);
                    setState(() {});
                  },
                  title: const Text(
                    'Smart File Organization',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  subtitle: const Text(
                    'Suggest categorized folders upon receiving files',
                    style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
                  ),
                  activeColor: AppColors.primaryBlack,
                ),
                const Divider(height: 1, color: AppColors.borderGray),
                SwitchListTile(
                  value: _aiConfig.failureAnomalyDetection,
                  onChanged: (val) async {
                    await _aiConfig.setFailureAnomalyDetection(val);
                    setState(() {});
                  },
                  title: const Text(
                    'Transfer Failure Detection',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBlack,
                    ),
                  ),
                  subtitle: const Text(
                    'Diagnose speed drops and repeated checksum mismatches',
                    style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
                  ),
                  activeColor: AppColors.primaryBlack,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s24),
      ],
    );
  }

  void _showApiKeyDialog() {
    final controller = TextEditingController(text: _aiConfig.geminiApiKey);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Google Gemini API Key',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your Gemini API key to enable cloud reasoning. Stored securely on your device, never hard-coded.',
              style: TextStyle(fontSize: 13, color: AppColors.mediumGray),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'AIzaSy...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _aiConfig.setGeminiApiKey(controller.text);
              setState(() {});
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showEditDeviceNameDialog() {
    final controller = TextEditingController(text: _deviceName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Edit Device Name',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter device name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await _settings.setDeviceName(newName);
                setState(() => _deviceName = newName);
              }
              if (mounted) Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showStorageLocationDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.backgroundWhite,
        shape: AppShapes.cardShape,
        title: const Text(
          'Storage Location',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.primaryBlack,
          ),
        ),
        content: Text(
          'Files received via FluxShare are stored securely in:\n$_storageLocation\n\nOn Android, completed and verified transfers are automatically exported to Public Downloads/FluxShare.',
          style: const TextStyle(fontSize: 14, color: AppColors.darkGray),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
