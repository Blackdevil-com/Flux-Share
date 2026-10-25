import 'dart:async';
import 'ai_config.dart';
import 'ai_models.dart';
import 'ai_provider.dart';
import 'ai_tools.dart';
import 'failure_detector.dart';
import 'file_classifier.dart';
import 'smart_organizer.dart';
import 'smart_search.dart';
import 'smart_summary.dart';
import 'transfer_optimizer.dart';

/// Central singleton facade orchestrating all AI capabilities for FLUXSHARE.
/// Completely decoupled from deterministic core networking and storage.
class AIService {
  static final AIService _instance = AIService._internal();
  factory AIService() => _instance;
  AIService._internal();

  final AIConfig _config = AIConfig();
  late final AIFileClassifier _classifier;
  late final SmartFileOrganizer _organizer;
  late final IntelligentTransferOptimizer _optimizer;
  late final AIFailureDetector _failureDetector;
  late final SmartFileSearch _smartSearch;
  late final SmartTransferSummaryService _summaryService;
  late final LocalRuleBasedProvider _localProvider;
  late final GeminiCloudProvider _geminiProvider;

  // In-memory cache for file classifications and quick assistant answers
  final Map<String, AIClassificationResult> _classificationCache = {};
  final List<AIAssistantMessage> _assistantHistory = [];

  bool _isInitialized = false;

  AIConfig get config => _config;
  AIFileClassifier get classifier => _classifier;
  SmartFileOrganizer get organizer => _organizer;
  IntelligentTransferOptimizer get optimizer => _optimizer;
  AIFailureDetector get failureDetector => _failureDetector;
  SmartFileSearch get smartSearch => _smartSearch;
  SmartTransferSummaryService get summaryService => _summaryService;
  List<AIAssistantMessage> get assistantHistory => List.unmodifiable(_assistantHistory);

  /// Initializes configuration and child engines.
  Future<void> init() async {
    if (_isInitialized) return;

    await _config.init();

    _localProvider = LocalRuleBasedProvider();
    _geminiProvider = GeminiCloudProvider();
    _classifier = AIFileClassifier(config: _config, cloudProvider: _geminiProvider);
    _organizer = SmartFileOrganizer(classifier: _classifier);
    _optimizer = IntelligentTransferOptimizer();
    _failureDetector = AIFailureDetector();
    _smartSearch = SmartFileSearch();
    _summaryService = SmartTransferSummaryService(config: _config, cloudProvider: _geminiProvider);

    _isInitialized = true;
  }

  /// Classifies a file, checking in-memory cache first for fast response.
  Future<AIClassificationResult> classifyFile({
    required String fileName,
    int sizeBytes = 0,
    String? filePath,
  }) async {
    if (!_config.isAiEnabled) {
      // Deterministic immediate fallback if AI is disabled
      return AIClassificationResult(
        category: AIFileCategory.other,
        confidence: 1.0,
        fileType: 'File',
        suggestedFolder: 'Downloads',
        mimeType: 'application/octet-stream',
        explanation: 'AI features disabled.',
      );
    }

    final cacheKey = '$fileName-$sizeBytes';
    if (_classificationCache.containsKey(cacheKey)) {
      return _classificationCache[cacheKey]!;
    }

    final result = await _classifier.classifyFile(
      fileName: fileName,
      sizeBytes: sizeBytes,
      filePath: filePath,
    );

    _classificationCache[cacheKey] = result;
    return result;
  }

  /// Handles conversational inquiries in the AI Assistant using structured application tools.
  Future<AIAssistantMessage> askAssistant(String question) async {
    final userMsg = AIAssistantMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}_user',
      role: 'user',
      content: question,
      timestamp: DateTime.now(),
    );
    _assistantHistory.add(userMsg);

    if (!_config.isAiEnabled) {
      final disabledMsg = AIAssistantMessage(
        id: 'msg_${DateTime.now().millisecondsSinceEpoch}_ai',
        role: 'assistant',
        content: 'FLUXSHARE AI capabilities are currently disabled in Settings. '
            'You can enable AI assistance under Settings > AI & Privacy.',
        timestamp: DateTime.now(),
      );
      _assistantHistory.add(disabledMsg);
      return disabledMsg;
    }

    final lower = question.toLowerCase().trim();
    final List<String> toolBadges = [];
    String answer = '';
    List<String> suggestedQuestions = [];

    try {
      // Intent 1: "Why is my transfer slow?" / "How can I improve transfer speed?"
      if (lower.contains('slow') || lower.contains('improve speed') || lower.contains('speed up')) {
        toolBadges.add('get_network_statistics()');
        toolBadges.add('get_transfer_statistics()');
        final netStats = await AITools.getNetworkStatistics();
        final transferStats = await AITools.getTransferStatistics();

        final avgSpeed = transferStats['averageThroughputMbPerSec'] ?? 0.0;
        final retransmissions = transferStats['totalRetransmissions'] ?? 0;
        final nearbyDevices = netStats['discoveredNearbyDevicesCount'] ?? 0;

        answer =
            '**Transfer Performance Analysis:**\n\n'
            '• Average Speed: **${avgSpeed.toStringAsFixed(1)} MB/s**\n'
            '• Total Retransmissions: **$retransmissions packets**\n'
            '• Swarm Devices Nearby: **$nearbyDevices devices**\n\n'
            '**Recommendations:**\n'
            '1. Ensure both devices are connected to 5 GHz Wi-Fi or a direct Wi-Fi hotspot.\n'
            '2. Move devices closer to reduce packet attenuation.\n'
            '3. In active transfers, tap **"Apply Recommendation"** to optimize chunk sizing and worker streams.';

        suggestedQuestions = [
          'Show me transfer statistics',
          'Which transfer failed?',
          'Find large files',
        ];
      }
      // Intent 2: "How many files did I receive today?" / "How much data did I transfer today?"
      else if (lower.contains('received today') || lower.contains('transfer today') || lower.contains('today')) {
        toolBadges.add('get_transfer_history()');
        final history = await AITools.getTransferHistory(limit: 50);
        final now = DateTime.now();

        int todayReceivedCount = 0;
        int todayReceivedBytes = 0;
        int todaySentCount = 0;
        int todaySentBytes = 0;

        for (final item in history) {
          final timeStr = item['timestamp'] as String? ?? '';
          final date = DateTime.tryParse(timeStr);
          if (date != null &&
              date.year == now.year &&
              date.month == now.month &&
              date.day == now.day) {
            final bytes = (item['sizeBytes'] as num?)?.toInt() ?? 0;
            if (item['direction'] == 'received') {
              todayReceivedCount++;
              todayReceivedBytes += bytes;
            } else {
              todaySentCount++;
              todaySentBytes += bytes;
            }
          }
        }

        answer =
            '**Today\'s Transfer Activity:**\n\n'
            '• Received: **$todayReceivedCount files** (${_formatBytes(todayReceivedBytes)})\n'
            '• Sent: **$todaySentCount files** (${_formatBytes(todaySentBytes)})\n'
            '• Total Volume Today: **${_formatBytes(todayReceivedBytes + todaySentBytes)}**';

        suggestedQuestions = [
          'Show me the largest files I received',
          'Why is my transfer slow?',
          'Show storage statistics',
        ];
      }
      // Intent 3: "Which transfer failed?" / "Why did this file fail?"
      else if (lower.contains('fail') || lower.contains('error')) {
        toolBadges.add('get_failed_transfers()');
        final failed = await AITools.getFailedTransfers();

        if (failed.isEmpty) {
          answer = 'Good news! All recorded transfers completed successfully with zero verified transfer failures.';
        } else {
          final count = failed.length;
          final names = failed.take(3).map((f) => '• **${f['fileName']}** (${f['size']})').join('\n');
          answer =
              'Found **$count failed transfer${count == 1 ? '' : 's'}**:\n\n$names\n\n'
              '**Diagnostic:**\n'
              'Failures were typically triggered by peer connection drops or network timeouts. '
              'Because FLUXSHARE uses chunk-based transfers, uncorrupted chunks are already saved on disk and can be resumed.';
        }

        suggestedQuestions = [
          'Why is my transfer slow?',
          'How can I improve transfer speed?',
          'Show storage statistics',
        ];
      }
      // Intent 4: "Show me the largest files I received" / "Find large files"
      else if (lower.contains('largest') || lower.contains('large file') || lower.contains('biggest')) {
        toolBadges.add('get_transfer_history()');
        final history = await AITools.getTransferHistory(limit: 50);
        final received = history.where((t) => t['direction'] == 'received').toList();
        received.sort((a, b) => ((b['sizeBytes'] as num?) ?? 0).compareTo((a['sizeBytes'] as num?) ?? 0));

        if (received.isEmpty) {
          answer = 'No received files found in the transfer repository yet.';
        } else {
          final top = received.take(3).map((f) => '• **${f['fileName']}** — ${f['size']} (at ${f['speedMbPerSec']} MB/s)').join('\n');
          answer = '**Top Largest Received Files:**\n\n$top';
        }

        suggestedQuestions = [
          'Show storage statistics',
          'How many files did I receive today?',
          'Organize my received files',
        ];
      }
      // Intent 5: "Show storage statistics" / "How much storage is used?"
      else if (lower.contains('storage') || lower.contains('disk') || lower.contains('space')) {
        toolBadges.add('get_storage_statistics()');
        final storage = await AITools.getStorageStatistics();

        answer =
            '**FLUXSHARE Local Storage:**\n\n'
            '• Stored Files: **${storage['localFilesCount']} files**\n'
            '• Total Space Occupied: **${storage['totalStorageUsedFormatted']}**\n'
            '• Target Directory: `${storage['downloadFolderPath']}`';

        suggestedQuestions = [
          'Find large files',
          'How many files did I receive today?',
          'Why is my transfer slow?',
        ];
      }
      // Intent 6: General transfer stats
      else if (lower.contains('statistic') || lower.contains('history') || lower.contains('summary')) {
        toolBadges.add('get_transfer_statistics()');
        final stats = await AITools.getTransferStatistics();

        answer =
            '**Cumulative Transfer Statistics:**\n\n'
            '• Total Transferred Files: **${stats['totalTransfers']}**\n'
            '• Successful Deliveries: **${stats['completedTransfers']}**\n'
            '• Total Uploaded: **${stats['totalSentFormatted']}**\n'
            '• Total Downloaded: **${stats['totalReceivedFormatted']}**\n'
            '• Average Throughput: **${stats['averageThroughputMbPerSec']} MB/s**';

        suggestedQuestions = [
          'Why is my transfer slow?',
          'Show me the largest files I received',
          'Show storage statistics',
        ];
      }
      // General / Cloud fallback
      else {
        toolBadges.add('get_network_statistics()');
        if (_config.isUsingCloud) {
          answer = await _geminiProvider.generateResponse(prompt: question);
        } else {
          answer = await _localProvider.generateResponse(prompt: question);
        }
        suggestedQuestions = [
          'Why is my transfer slow?',
          'How many files did I receive today?',
          'Show me the largest files I received',
          'Show storage statistics',
        ];
      }
    } catch (e) {
      answer = 'I encountered an error retrieving data: $e. You can still view active and past transfers directly in the Transfers and History tabs.';
    }

    final responseMsg = AIAssistantMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}_ai',
      role: 'assistant',
      content: answer,
      timestamp: DateTime.now(),
      toolBadges: toolBadges,
      suggestedQuestions: suggestedQuestions,
    );

    _assistantHistory.add(responseMsg);
    return responseMsg;
  }

  void clearAssistantHistory() {
    _assistantHistory.clear();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
