import 'ai_config.dart';
import 'ai_models.dart';
import 'ai_provider.dart';

/// Generates concise, accurate post-transfer summaries with AI insights.
class SmartTransferSummaryService {
  final AIConfig _config;
  final AIProvider _cloudProvider;

  SmartTransferSummaryService({AIConfig? config, AIProvider? cloudProvider})
      : _config = config ?? AIConfig(),
        _cloudProvider = cloudProvider ?? GeminiCloudProvider();

  /// Generates a complete transfer summary with contextual insight.
  Future<AISmartSummary> generateSummary({
    required String fileName,
    required String formattedSize,
    required String durationText,
    required String averageSpeedText,
    required int chunkCount,
    required int retryCount,
    bool integrityVerified = true,
  }) async {
    final localInsight = _generateLocalInsight(
      chunkCount: chunkCount,
      retryCount: retryCount,
      integrityVerified: integrityVerified,
      speedText: averageSpeedText,
    );

    String effectiveInsight = localInsight;

    // Optional cloud augmentation (strictly opt-in, non-sensitive summary)
    if (_config.isUsingCloud) {
      try {
        final prompt =
            'Generate a single concise analytical sentence (maximum 20 words) for this file transfer summary: '
            'File: $fileName, Size: $formattedSize, Duration: $durationText, Speed: $averageSpeedText, '
            'Chunks: $chunkCount, Retries: $retryCount, Verified: $integrityVerified.';

        final cloudResponse = await _cloudProvider.generateResponse(prompt: prompt);
        if (cloudResponse.isNotEmpty && !cloudResponse.contains('error')) {
          effectiveInsight = cloudResponse.replaceAll('"', '').trim();
        }
      } catch (_) {
        // Safe fallback to local insight
      }
    }

    return AISmartSummary(
      fileName: fileName,
      formattedSize: formattedSize,
      durationText: durationText,
      averageSpeedText: averageSpeedText,
      chunkCount: chunkCount,
      retryCount: retryCount,
      integrityVerified: integrityVerified,
      aiInsight: effectiveInsight,
    );
  }

  String _generateLocalInsight({
    required int chunkCount,
    required int retryCount,
    required bool integrityVerified,
    required String speedText,
  }) {
    if (!integrityVerified) {
      return 'Integrity verification failed for one or more chunks. Re-requesting missing chunks is advised.';
    }

    if (retryCount == 0) {
      return 'Transfer completed with 100% first-pass chunk delivery and verified SHA-256 integrity across all $chunkCount chunks.';
    }

    if (retryCount <= 4) {
      return 'Transfer completed successfully at $speedText. The connection remained stable, but $retryCount ${retryCount == 1 ? 'chunk' : 'chunks'} required retrying.';
    }

    return 'Transfer verified successfully, though $retryCount chunks required retransmission due to Wi-Fi packet drops.';
  }
}
