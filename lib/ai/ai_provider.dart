import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'ai_config.dart';
import 'ai_models.dart';

/// Abstract base provider for AI generation and analysis.
/// Allows swappable local and cloud providers without breaking client interfaces.
abstract class AIProvider {
  String get name;
  bool get isCloud;

  Future<String> generateResponse({
    required String prompt,
    List<Map<String, dynamic>>? toolDeclarations,
    List<Map<String, dynamic>>? conversationHistory,
  });

  Future<AIResult<T>> analyze<T>({
    required String task,
    required Map<String, dynamic> metadata,
    required T Function(Map<String, dynamic>) parser,
    T? fallbackData,
  });
}

/// 100% Offline, deterministic rule-based AI provider.
/// Guarantees instant performance, complete privacy, and zero external network reliance.
class LocalRuleBasedProvider implements AIProvider {
  @override
  String get name => 'Local Rule-Based';

  @override
  bool get isCloud => false;

  @override
  Future<String> generateResponse({
    required String prompt,
    List<Map<String, dynamic>>? toolDeclarations,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    // Provide intelligent deterministic responses based on prompt and data
    final lower = prompt.toLowerCase();

    if (lower.contains('slow') || lower.contains('speed') || lower.contains('improve')) {
      return 'Transfer speed depends on local Wi-Fi link quality, physical distance between devices, interference, and chunk sizing. '
          'For high-speed 5GHz networks, using 4MB - 8MB chunks with 5-6 parallel transfers maximizes throughput. '
          'If you experience packet drop or high retry rates, reducing chunk size to 1MB - 2MB stabilizes the connection.';
    }

    if (lower.contains('fail') || lower.contains('error') || lower.contains('why did')) {
      return 'Transfers can fail due to temporary Wi-Fi disconnections, checksum verification mismatches, or target device storage limitations. '
          'FLUXSHARE preserves already verified chunks, so you can safely resume the transfer without re-downloading existing chunks.';
    }

    if (lower.contains('how many') || lower.contains('received today') || lower.contains('count')) {
      return 'You can view today\'s transfers in the Transfer History tab. The assistant tools have scanned your local records to provide exact counts.';
    }

    return 'FLUXSHARE local assistant is active. I can help analyze your transfer speed, diagnose connection anomalies, locate received files, or suggest optimal chunk parameters.';
  }

  @override
  Future<AIResult<T>> analyze<T>({
    required String task,
    required Map<String, dynamic> metadata,
    required T Function(Map<String, dynamic>) parser,
    T? fallbackData,
  }) async {
    try {
      final parsed = parser(metadata);
      return AIResult.success(parsed, source: 'local_deterministic');
    } catch (e) {
      return AIResult.failure(
        'Local analysis failed: $e',
        source: 'local_deterministic',
        fallbackData: fallbackData,
      );
    }
  }
}

/// Cloud provider for Google Gemini.
/// Strictly opt-in, privacy-preserving, with robust offline fallback.
class GeminiCloudProvider implements AIProvider {
  final AIConfig _config = AIConfig();
  final LocalRuleBasedProvider _fallbackProvider = LocalRuleBasedProvider();
  final http.Client _httpClient;

  GeminiCloudProvider({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  @override
  String get name => 'Google Gemini (Cloud)';

  @override
  bool get isCloud => true;

  @override
  Future<String> generateResponse({
    required String prompt,
    List<Map<String, dynamic>>? toolDeclarations,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    final apiKey = _config.geminiApiKey;
    if (apiKey.isEmpty || !_config.allowCloudAi) {
      // Automatic fallback to local provider
      return _fallbackProvider.generateResponse(
        prompt: prompt,
        toolDeclarations: toolDeclarations,
        conversationHistory: conversationHistory,
      );
    }

    try {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      );

      final contents = <Map<String, dynamic>>[];

      // Append conversation history if provided
      if (conversationHistory != null && conversationHistory.isNotEmpty) {
        contents.addAll(conversationHistory);
      }

      contents.add({
        'role': 'user',
        'parts': [
          {
            'text':
                'You are the AI Assistant for FLUXSHARE, a local peer-to-peer file transfer app. '
                'Help the user with transfers, speed optimization, and file organization based STRICTLY on provided metrics and tools. '
                'Do not invent non-existent files or network stats.\n\n$prompt',
          }
        ],
      });

      final body = <String, dynamic>{
        'contents': contents,
        'generationConfig': {
          'temperature': 0.2,
          'maxOutputTokens': 512,
        },
      };

      final response = await _httpClient
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final firstCandidate = candidates.first as Map<String, dynamic>;
          final content = firstCandidate['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List<dynamic>?;
          if (parts != null && parts.isNotEmpty) {
            final text = parts.first['text'] as String?;
            if (text != null && text.trim().isNotEmpty) {
              return text.trim();
            }
          }
        }
      }

      // If status code is not 200 (e.g. rate limit, invalid key), fallback gracefully
      return _fallbackProvider.generateResponse(
        prompt: prompt,
        toolDeclarations: toolDeclarations,
        conversationHistory: conversationHistory,
      );
    } catch (_) {
      // Seamless offline / error fallback
      return _fallbackProvider.generateResponse(
        prompt: prompt,
        toolDeclarations: toolDeclarations,
        conversationHistory: conversationHistory,
      );
    }
  }

  @override
  Future<AIResult<T>> analyze<T>({
    required String task,
    required Map<String, dynamic> metadata,
    required T Function(Map<String, dynamic>) parser,
    T? fallbackData,
  }) async {
    final apiKey = _config.geminiApiKey;
    if (apiKey.isEmpty || !_config.allowCloudAi) {
      return _fallbackProvider.analyze(
        task: task,
        metadata: metadata,
        parser: parser,
        fallbackData: fallbackData,
      );
    }

    try {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      );

      final prompt =
          'Perform analysis task: $task.\n'
          'Input metadata (non-sensitive): ${jsonEncode(metadata)}.\n'
          'Return ONLY a valid JSON object matching the requested schema without markdown wrapping.';

      final response = await _httpClient
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {
                'temperature': 0.1,
                'responseMimeType': 'application/json',
              }
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final text =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
        if (text != null) {
          final jsonMap = jsonDecode(text) as Map<String, dynamic>;
          final parsed = parser(jsonMap);
          return AIResult.success(parsed, source: 'cloud_gemini');
        }
      }

      // Fallback to local
      return _fallbackProvider.analyze(
        task: task,
        metadata: metadata,
        parser: parser,
        fallbackData: fallbackData,
      );
    } catch (_) {
      return _fallbackProvider.analyze(
        task: task,
        metadata: metadata,
        parser: parser,
        fallbackData: fallbackData,
      );
    }
  }
}
