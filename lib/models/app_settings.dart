import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Centralized application settings model with persistent storage on device.
///
/// Ensures user preferences for device name, auto-accept, connection concurrency,
/// and notifications are persisted across app restarts without fake or volatile state.
class AppSettings {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  bool _isInitialized = false;

  String _deviceName = 'FluxShare Device';
  bool _autoAccept = false;
  int _maxParallelConnections = 5;
  bool _showNotifications = true;
  String _customDownloadPath = '';

  String get deviceName => _deviceName;
  bool get autoAccept => _autoAccept;
  int get maxParallelConnections => _maxParallelConnections;
  bool get showNotifications => _showNotifications;
  String get customDownloadPath => _customDownloadPath;

  /// Initializes settings from disk.
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        _deviceName = map['deviceName'] as String? ?? _deviceName;
        _autoAccept = map['autoAccept'] as bool? ?? _autoAccept;
        _maxParallelConnections = (map['maxParallelConnections'] as num?)?.toInt() ?? _maxParallelConnections;
        _showNotifications = map['showNotifications'] as bool? ?? _showNotifications;
        _customDownloadPath = map['customDownloadPath'] as String? ?? '';
      }
      _isInitialized = true;
    } catch (_) {
      _isInitialized = true;
    }
  }

  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) {
      _deviceName = trimmed;
      await _save();
    }
  }

  Future<void> setAutoAccept(bool value) async {
    _autoAccept = value;
    await _save();
  }

  Future<void> setMaxParallelConnections(int count) async {
    _maxParallelConnections = count.clamp(1, 10);
    await _save();
  }

  Future<void> setShowNotifications(bool value) async {
    _showNotifications = value;
    await _save();
  }

  Future<void> setCustomDownloadPath(String path) async {
    _customDownloadPath = path.trim();
    await _save();
  }

  Future<File> _getSettingsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/fluxshare_app_settings.json');
  }

  Future<void> _save() async {
    try {
      final file = await _getSettingsFile();
      final map = {
        'deviceName': _deviceName,
        'autoAccept': _autoAccept,
        'maxParallelConnections': _maxParallelConnections,
        'showNotifications': _showNotifications,
        'customDownloadPath': _customDownloadPath,
      };
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {}
  }
}
