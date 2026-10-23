// Models for FLUXSHARE AI assistance and optimization layer.

enum AIFileCategory {
  images,
  videos,
  audio,
  documents,
  pdfs,
  presentations,
  spreadsheets,
  archives,
  code,
  other;

  String get displayName {
    switch (this) {
      case AIFileCategory.images:
        return 'Images';
      case AIFileCategory.videos:
        return 'Videos';
      case AIFileCategory.audio:
        return 'Audio';
      case AIFileCategory.documents:
        return 'Documents';
      case AIFileCategory.pdfs:
        return 'PDFs';
      case AIFileCategory.presentations:
        return 'Presentations';
      case AIFileCategory.spreadsheets:
        return 'Spreadsheets';
      case AIFileCategory.archives:
        return 'Archives';
      case AIFileCategory.code:
        return 'Code';
      case AIFileCategory.other:
        return 'Other';
    }
  }

  String get defaultSuggestedFolder {
    switch (this) {
      case AIFileCategory.images:
        return 'Photos';
      case AIFileCategory.videos:
        return 'Videos';
      case AIFileCategory.audio:
        return 'Music';
      case AIFileCategory.documents:
        return 'Documents';
      case AIFileCategory.pdfs:
        return 'PDFs';
      case AIFileCategory.presentations:
        return 'Presentations';
      case AIFileCategory.spreadsheets:
        return 'Spreadsheets';
      case AIFileCategory.archives:
        return 'Archives';
      case AIFileCategory.code:
        return 'Development';
      case AIFileCategory.other:
        return 'Downloads';
    }
  }

  static AIFileCategory fromString(String val) {
    final lower = val.toLowerCase().trim();
    if (lower.contains('image') || lower.contains('photo') || lower.contains('picture')) {
      return AIFileCategory.images;
    }
    if (lower.contains('video') || lower.contains('movie')) {
      return AIFileCategory.videos;
    }
    if (lower.contains('audio') || lower.contains('music') || lower.contains('sound') || lower.contains('song')) {
      return AIFileCategory.audio;
    }
    if (lower == 'pdf' || lower == 'pdfs') {
      return AIFileCategory.pdfs;
    }
    if (lower.contains('presentation') || lower.contains('ppt') || lower.contains('slide')) {
      return AIFileCategory.presentations;
    }
    if (lower.contains('spreadsheet') || lower.contains('excel') || lower.contains('sheet') || lower.contains('csv')) {
      return AIFileCategory.spreadsheets;
    }
    if (lower.contains('document') || lower.contains('doc') || lower.contains('text')) {
      return AIFileCategory.documents;
    }
    if (lower.contains('archive') || lower.contains('zip') || lower.contains('tar') || lower.contains('compressed')) {
      return AIFileCategory.archives;
    }
    if (lower.contains('code') || lower.contains('source') || lower.contains('developer') || lower.contains('script')) {
      return AIFileCategory.code;
    }
    return AIFileCategory.other;
  }
}

class AIClassificationResult {
  final AIFileCategory category;
  final double confidence; // e.g., 0.98 -> 98%
  final String fileType;
  final String suggestedFolder;
  final String mimeType;
  final String explanation;

  const AIClassificationResult({
    required this.category,
    required this.confidence,
    required this.fileType,
    required this.suggestedFolder,
    required this.mimeType,
    required this.explanation,
  });

  int get confidencePercentage => (confidence * 100).round().clamp(0, 100);

  Map<String, dynamic> toMap() => {
    'category': category.displayName,
    'confidence': confidence,
    'fileType': fileType,
    'suggestedFolder': suggestedFolder,
    'mimeType': mimeType,
    'explanation': explanation,
  };

  factory AIClassificationResult.fromMap(Map<String, dynamic> map) => AIClassificationResult(
    category: AIFileCategory.fromString(map['category'] ?? ''),
    confidence: (map['confidence'] as num?)?.toDouble() ?? 0.9,
    fileType: map['fileType'] ?? 'Unknown',
    suggestedFolder: map['suggestedFolder'] ?? 'Downloads',
    mimeType: map['mimeType'] ?? 'application/octet-stream',
    explanation: map['explanation'] ?? '',
  );
}

class AIOrganizationSuggestion {
  final String destinationFolder;
  final List<String> fileNames;
  final AIFileCategory category;
  bool isAccepted;

  AIOrganizationSuggestion({
    required this.destinationFolder,
    required this.fileNames,
    required this.category,
    this.isAccepted = true,
  });

  Map<String, dynamic> toMap() => {
    'destinationFolder': destinationFolder,
    'fileNames': fileNames,
    'category': category.displayName,
    'isAccepted': isAccepted,
  };
}

class AIBatchOrganizationPlan {
  final List<AIOrganizationSuggestion> suggestions;
  final String summary;

  const AIBatchOrganizationPlan({
    required this.suggestions,
    required this.summary,
  });
}

class AITransferOptimization {
  final int recommendedChunkSize; // bytes
  final String recommendedChunkSizeLabel;
  final int recommendedParallelWorkers;
  final String retryStrategy;
  final int timeoutSeconds;
  final bool useParallel;
  final String reason;
  final double confidence;
  bool isApplied;

  AITransferOptimization({
    required this.recommendedChunkSize,
    required this.recommendedChunkSizeLabel,
    required this.recommendedParallelWorkers,
    required this.retryStrategy,
    required this.timeoutSeconds,
    required this.useParallel,
    required this.reason,
    required this.confidence,
    this.isApplied = false,
  });

  Map<String, dynamic> toMap() => {
    'recommendedChunkSize': recommendedChunkSize,
    'recommendedChunkSizeLabel': recommendedChunkSizeLabel,
    'recommendedParallelWorkers': recommendedParallelWorkers,
    'retryStrategy': retryStrategy,
    'timeoutSeconds': timeoutSeconds,
    'useParallel': useParallel,
    'reason': reason,
    'confidence': confidence,
    'isApplied': isApplied,
  };
}

enum AIFailureSeverity {
  low,
  medium,
  high,
  critical;

  String get displayName {
    switch (this) {
      case AIFailureSeverity.low:
        return 'Notice';
      case AIFailureSeverity.medium:
        return 'Warning';
      case AIFailureSeverity.high:
        return 'High Alert';
      case AIFailureSeverity.critical:
        return 'Critical Error';
    }
  }
}

enum AIFailureActionType {
  retry,
  reduceChunkSize,
  reduceParallel,
  reconnect,
  resume;

  String get actionLabel {
    switch (this) {
      case AIFailureActionType.retry:
        return 'Retry Transfer';
      case AIFailureActionType.reduceChunkSize:
        return 'Reduce Chunk Size';
      case AIFailureActionType.reduceParallel:
        return 'Reduce Parallel Transfers';
      case AIFailureActionType.reconnect:
        return 'Reconnect to Peer';
      case AIFailureActionType.resume:
        return 'Resume Transfer';
    }
  }
}

class AIFailureDiagnosis {
  final bool issueDetected;
  final AIFailureSeverity severity;
  final String explanation;
  final String recommendedAction;
  final AIFailureActionType actionType;
  final int? recommendedChunkSize;
  final int? recommendedWorkers;

  const AIFailureDiagnosis({
    required this.issueDetected,
    required this.severity,
    required this.explanation,
    required this.recommendedAction,
    required this.actionType,
    this.recommendedChunkSize,
    this.recommendedWorkers,
  });

  static const normal = AIFailureDiagnosis(
    issueDetected: false,
    severity: AIFailureSeverity.low,
    explanation: 'Transfer connection is performing normally within expected parameters.',
    recommendedAction: 'No action needed.',
    actionType: AIFailureActionType.resume,
  );
}

class AISmartSummary {
  final String fileName;
  final String formattedSize;
  final String durationText;
  final String averageSpeedText;
  final int chunkCount;
  final int retryCount;
  final bool integrityVerified;
  final String aiInsight;

  const AISmartSummary({
    required this.fileName,
    required this.formattedSize,
    required this.durationText,
    required this.averageSpeedText,
    required this.chunkCount,
    required this.retryCount,
    required this.integrityVerified,
    required this.aiInsight,
  });
}

class AIAssistantMessage {
  final String id;
  final String role; // 'user', 'assistant', 'tool'
  final String content;
  final DateTime timestamp;
  final List<String> toolBadges;
  final List<String> suggestedQuestions;

  const AIAssistantMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.toolBadges = const [],
    this.suggestedQuestions = const [],
  });
}

class StructuredFileFilter {
  final AIFileCategory? category;
  final int? minSizeBytes;
  final int? maxSizeBytes;
  final String? dateRange; // 'today', 'yesterday', 'this_week', 'this_month'
  final String? peerSender;
  final String rawQuery;

  const StructuredFileFilter({
    this.category,
    this.minSizeBytes,
    this.maxSizeBytes,
    this.dateRange,
    this.peerSender,
    required this.rawQuery,
  });

  bool get isEmpty =>
      category == null &&
      minSizeBytes == null &&
      maxSizeBytes == null &&
      dateRange == null &&
      (peerSender == null || peerSender!.isEmpty) &&
      rawQuery.trim().isEmpty;
}

class AIResult<T> {
  final bool success;
  final T? data;
  final String source; // 'local_deterministic', 'cloud_gemini', 'fallback'
  final String? errorMessage;

  const AIResult({
    required this.success,
    this.data,
    required this.source,
    this.errorMessage,
  });

  factory AIResult.success(T data, {String source = 'local_deterministic'}) => AIResult(
    success: true,
    data: data,
    source: source,
  );

  factory AIResult.failure(String error, {String source = 'fallback', T? fallbackData}) => AIResult(
    success: false,
    data: fallbackData,
    source: source,
    errorMessage: error,
  );
}
