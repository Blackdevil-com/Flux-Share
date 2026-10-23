import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum AIProviderType {
  local,
  gemini;

  String get displayName {
    switch (this) {
      case AIProviderType.local:
        return 'Local Rule-Based (100% Offline & Private)';
      case AIProviderType.gemini:
        return 'Google Gemini (Cloud AI)';
    }
  }

  static AIProviderType fromString(String val) {
    if (val.toLowerCase().contains('gemini')) {
      return AIProviderType.gemini;
    }
    return AIProviderType.local;
  }
}

/// Configuration and privacy guard for FLUXSHARE AI services.
/// Manages preferences, API keys, and privacy boundaries.
class AIConfig extends ChangeNotifier {
  static final AIConfig _instance = AIConfig._internal();
  factory AIConfig() => _instance;
  AIConfig._internal();

  bool _isInitialized = false;

  // Master toggle: if false, no AI processes run and UI falls back to pure deterministic views
  bool _isAiEnabled = true;

  // Privacy-first toggle: by default, NO data is ever sent to external cloud APIs
  bool _allowCloudAi = false;

  // Current active provider
  AIProviderType _providerType = AIProviderType.local;

  // API Key for Google Gemini:
  // Can be provided via compile-time --dart-define=GEMINI_API_KEY=xxx
  // or entered by the user in Settings. Stored locally, never committed to git.
  String _geminiApiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  // Specific feature toggles
  bool _autoSuggestOrganization = true;
  bool _liveTransferOptimization = true;
  bool _failureAnomalyDetection = true;

  bool get isAiEnabled => _isAiEnabled;
  bool get allowCloudAi => _allowCloudAi;
  AIProviderType get providerType => _providerType;
  String get geminiApiKey => _geminiApiKey;
  bool get hasValidApiKey => _geminiApiKey.trim().isNotEmpty;
  bool get autoSuggestOrganization => _autoSuggestOrganization;
  bool get liveTransferOptimization => _liveTransferOptimization;
  bool get failureAnomalyDetection => _failureAnomalyDetection;

  /// Effective provider in use considering network and privacy restrictions
  bool get isUsingCloud => _isAiEnabled && _allowCloudAi && _providerType == AIProviderType.gemini && hasValidApiKey;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        _isAiEnabled = map['isAiEnabled'] as bool? ?? true;
        _allowCloudAi = map['allowCloudAi'] as bool? ?? false;
        _providerType = AIProviderType.fromString(map['providerType'] as String? ?? 'local');
        
        final savedKey = map['geminiApiKey'] as String?;
        if (savedKey != null && savedKey.isNotEmpty) {
          // De-obfuscate stored key
          try {
            _geminiApiKey = utf8.decode(base64Decode(savedKey));
          } catch (_) {
            _geminiApiKey = savedKey;
          }
        }

        _autoSuggestOrganization = map['autoSuggestOrganization'] as bool? ?? true;
        _liveTransferOptimization = map['liveTransferOptimization'] as bool? ?? true;
        _failureAnomalyDetection = map['failureAnomalyDetection'] as bool? ?? true;
      }
      _isInitialized = true;
    } catch (_) {
      _isInitialized = true;
    }
  }

  Future<void> setAiEnabled(bool enabled) async {
    _isAiEnabled = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setAllowCloudAi(bool allowed) async {
    _allowCloudAi = allowed;
    // If cloud is disabled, ensure provider is set to local
    if (!allowed) {
      _providerType = AIProviderType.local;
    }
    notifyListeners();
    await _save();
  }

  Future<void> setProviderType(AIProviderType type) async {
    _providerType = type;
    notifyListeners();
    await _save();
  }

  Future<void> setGeminiApiKey(String key) async {
    _geminiApiKey = key.trim();
    notifyListeners();
    await _save();
  }

  Future<void> setAutoSuggestOrganization(bool enabled) async {
    _autoSuggestOrganization = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setLiveTransferOptimization(bool enabled) async {
    _liveTransferOptimization = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setFailureAnomalyDetection(bool enabled) async {
    _failureAnomalyDetection = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> resetToDefaults() async {
    _isAiEnabled = true;
    _allowCloudAi = false;
    _providerType = AIProviderType.local;
    _geminiApiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
    _autoSuggestOrganization = true;
    _liveTransferOptimization = true;
    _failureAnomalyDetection = true;
    notifyListeners();
    await _save();
  }

  Future<File> _getConfigFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/fluxshare_ai_config.json');
  }

  Future<void> _save() async {
    try {
      final file = await _getConfigFile();
      final map = {
        'isAiEnabled': _isAiEnabled,
        'allowCloudAi': _allowCloudAi,
        'providerType': _providerType.name,
        // Obfuscate in local file to avoid plaintext storage
        'geminiApiKey': _geminiApiKey.isNotEmpty ? base64Encode(utf8.encode(_geminiApiKey)) : '',
        'autoSuggestOrganization': _autoSuggestOrganization,
        'liveTransferOptimization': _liveTransferOptimization,
        'failureAnomalyDetection': _failureAnomalyDetection,
      };
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {}
  }
}
