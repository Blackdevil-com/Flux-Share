import 'dart:io';
import 'ai_config.dart';
import 'ai_models.dart';
import 'ai_provider.dart';

/// Intelligent file classifier analyzing metadata, extension, MIME type, and size.
/// Evaluates locally with zero file content leakage to external servers.
class AIFileClassifier {
  final AIConfig _config;
  final AIProvider _cloudProvider;

  AIFileClassifier({AIConfig? config, AIProvider? cloudProvider})
      : _config = config ?? AIConfig(),
        _cloudProvider = cloudProvider ?? GeminiCloudProvider();

  /// Classifies a file from its name, size, and optional path.
  Future<AIClassificationResult> classifyFile({
    required String fileName,
    int sizeBytes = 0,
    String? filePath,
  }) async {
    // 1. Compute deterministic local classification
    final localResult = _classifyLocally(fileName, sizeBytes);

    // 2. If user explicitly enabled cloud AI and has configured an API key,
    // optionally enhance the explanation using cloud AI (sending only metadata, NEVER content)
    if (_config.isUsingCloud) {
      try {
        final cloudAnalysis = await _cloudProvider.analyze<AIClassificationResult>(
          task: 'Classify file metadata into category, confidence, and suggested folder',
          metadata: {
            'fileName': fileName,
            'sizeBytes': sizeBytes,
            'localGuess': localResult.toMap(),
          },
          parser: (map) => AIClassificationResult.fromMap(map),
          fallbackData: localResult,
        );
        if (cloudAnalysis.success && cloudAnalysis.data != null) {
          return cloudAnalysis.data!;
        }
      } catch (_) {
        // Safe fallback to local result
      }
    }

    return localResult;
  }

  /// 100% Offline deterministic classifier.
  AIClassificationResult _classifyLocally(String fileName, int sizeBytes) {
    final name = fileName.trim();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

    AIFileCategory category;
    String fileType;
    String mimeType;
    double confidence = 0.98;
    String suggestedFolder;
    String explanation;

    switch (ext) {
      // Images
      case 'jpg':
      case 'jpeg':
        category = AIFileCategory.images;
        fileType = 'JPEG Image';
        mimeType = 'image/jpeg';
        suggestedFolder = 'Photos';
        explanation = 'Standard compressed photographic image format.';
        break;
      case 'png':
        category = AIFileCategory.images;
        fileType = 'PNG Image';
        mimeType = 'image/png';
        suggestedFolder = 'Photos';
        explanation = 'Lossless bitmap image with alpha transparency support.';
        break;
      case 'webp':
        category = AIFileCategory.images;
        fileType = 'WebP Image';
        mimeType = 'image/webp';
        suggestedFolder = 'Photos';
        explanation = 'Modern high-compression raster web image format.';
        break;
      case 'gif':
        category = AIFileCategory.images;
        fileType = 'GIF Animation';
        mimeType = 'image/gif';
        suggestedFolder = 'Photos';
        explanation = 'Compuserve animated image graphics file.';
        break;
      case 'svg':
        category = AIFileCategory.images;
        fileType = 'Vector Graphic';
        mimeType = 'image/svg+xml';
        suggestedFolder = 'Photos';
        explanation = 'Scalable vector graphic XML specification.';
        break;
      case 'heic':
      case 'heif':
        category = AIFileCategory.images;
        fileType = 'High Efficiency Image';
        mimeType = 'image/heic';
        suggestedFolder = 'Photos';
        explanation = 'Modern mobile High-Efficiency Image File.';
        break;
      case 'bmp':
      case 'tiff':
      case 'ico':
      case 'raw':
      case 'cr2':
      case 'nef':
        category = AIFileCategory.images;
        fileType = '${ext.toUpperCase()} Image';
        mimeType = 'image/$ext';
        suggestedFolder = 'Photos';
        explanation = 'Bitmap/Digital Camera RAW graphic image.';
        break;

      // Videos
      case 'mp4':
        category = AIFileCategory.videos;
        fileType = 'MPEG-4 Video';
        mimeType = 'video/mp4';
        suggestedFolder = 'Videos';
        explanation = 'Universal digital multimedia container format.';
        break;
      case 'mkv':
        category = AIFileCategory.videos;
        fileType = 'Matroska Video';
        mimeType = 'video/x-matroska';
        suggestedFolder = 'Videos';
        explanation = 'High-definition Matroska open standard video container.';
        break;
      case 'mov':
        category = AIFileCategory.videos;
        fileType = 'QuickTime Video';
        mimeType = 'video/quicktime';
        suggestedFolder = 'Videos';
        explanation = 'Apple QuickTime multimedia video container.';
        break;
      case 'avi':
      case 'webm':
      case 'flv':
      case 'wmv':
      case 'm4v':
      case '3gp':
        category = AIFileCategory.videos;
        fileType = '${ext.toUpperCase()} Video';
        mimeType = 'video/$ext';
        suggestedFolder = 'Videos';
        explanation = 'Compressed video playback stream.';
        break;

      // Audio
      case 'mp3':
        category = AIFileCategory.audio;
        fileType = 'MP3 Audio';
        mimeType = 'audio/mpeg';
        suggestedFolder = 'Music';
        explanation = 'MPEG-1 Audio Layer III compressed audio soundtrack.';
        break;
      case 'wav':
        category = AIFileCategory.audio;
        fileType = 'Waveform Audio';
        mimeType = 'audio/wav';
        suggestedFolder = 'Music';
        explanation = 'Uncompressed linear PCM waveform audio data.';
        break;
      case 'flac':
        category = AIFileCategory.audio;
        fileType = 'FLAC Lossless Audio';
        mimeType = 'audio/flac';
        suggestedFolder = 'Music';
        explanation = 'Free Lossless Audio Codec high-fidelity stream.';
        break;
      case 'aac':
      case 'm4a':
      case 'ogg':
      case 'wma':
      case 'opus':
        category = AIFileCategory.audio;
        fileType = '${ext.toUpperCase()} Audio';
        mimeType = 'audio/$ext';
        suggestedFolder = 'Music';
        explanation = 'Digital acoustic audio file.';
        break;

      // PDFs
      case 'pdf':
        category = AIFileCategory.pdfs;
        fileType = 'PDF Document';
        mimeType = 'application/pdf';
        suggestedFolder = 'PDFs';
        explanation = 'Adobe Portable Document Format standardized document.';
        break;

      // Presentations
      case 'ppt':
      case 'pptx':
        category = AIFileCategory.presentations;
        fileType = 'PowerPoint Presentation';
        mimeType = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
        suggestedFolder = 'Presentations';
        explanation = 'Microsoft PowerPoint presentation slide deck.';
        break;
      case 'odp':
      case 'key':
        category = AIFileCategory.presentations;
        fileType = 'Slide Presentation';
        mimeType = 'application/vnd.oasis.opendocument.presentation';
        suggestedFolder = 'Presentations';
        explanation = 'Digital slide deck presentation.';
        break;

      // Spreadsheets
      case 'xls':
      case 'xlsx':
        category = AIFileCategory.spreadsheets;
        fileType = 'Excel Spreadsheet';
        mimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
        suggestedFolder = 'Spreadsheets';
        explanation = 'Microsoft Excel structured tabular workbook.';
        break;
      case 'csv':
        category = AIFileCategory.spreadsheets;
        fileType = 'CSV Data Table';
        mimeType = 'text/csv';
        suggestedFolder = 'Spreadsheets';
        explanation = 'Comma-separated values tabular structured data.';
        break;
      case 'ods':
      case 'tsv':
        category = AIFileCategory.spreadsheets;
        fileType = 'Tabular Spreadsheet';
        mimeType = 'application/vnd.oasis.opendocument.spreadsheet';
        suggestedFolder = 'Spreadsheets';
        explanation = 'Structured spreadsheet calculations file.';
        break;

      // Documents
      case 'doc':
      case 'docx':
        category = AIFileCategory.documents;
        fileType = 'Word Document';
        mimeType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
        suggestedFolder = 'Documents';
        explanation = 'Microsoft Word rich text word processing document.';
        break;
      case 'txt':
        category = AIFileCategory.documents;
        fileType = 'Plain Text';
        mimeType = 'text/plain';
        suggestedFolder = 'Documents';
        explanation = 'Standard unformatted plain ASCII/UTF-8 text file.';
        break;
      case 'rtf':
      case 'odt':
      case 'md':
      case 'markdown':
        category = AIFileCategory.documents;
        fileType = 'Rich Text Document';
        mimeType = 'text/markdown';
        suggestedFolder = 'Documents';
        explanation = 'Formatted documentation or formatted notes file.';
        break;

      // Archives
      case 'zip':
        category = AIFileCategory.archives;
        fileType = 'ZIP Archive';
        mimeType = 'application/zip';
        suggestedFolder = 'Archives';
        explanation = 'Standard multi-file compressed ZIP bundle.';
        break;
      case 'tar':
      case 'gz':
      case 'tgz':
      case 'bz2':
      case 'xz':
      case '7z':
      case 'rar':
      case 'iso':
        category = AIFileCategory.archives;
        fileType = '${ext.toUpperCase()} Compressed Archive';
        mimeType = 'application/x-$ext';
        suggestedFolder = 'Archives';
        explanation = 'Compressed filesystem package or disk image.';
        break;
      case 'apk':
        category = AIFileCategory.archives;
        fileType = 'Android Application Package';
        mimeType = 'application/vnd.android.package-archive';
        suggestedFolder = 'Apps';
        explanation = 'Compiled Android application binary package.';
        break;

      // Code
      case 'dart':
      case 'kt':
      case 'kts':
      case 'java':
      case 'py':
      case 'js':
      case 'ts':
      case 'html':
      case 'css':
      case 'c':
      case 'cpp':
      case 'h':
      case 'hpp':
      case 'cs':
      case 'go':
      case 'rs':
      case 'swift':
      case 'rb':
      case 'php':
      case 'sh':
      case 'bat':
      case 'ps1':
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'sql':
        category = AIFileCategory.code;
        fileType = '${ext.toUpperCase()} Source Code';
        mimeType = 'text/x-$ext';
        suggestedFolder = 'Development';
        explanation = 'Software source code or configuration script.';
        break;

      default:
        category = AIFileCategory.other;
        fileType = ext.isNotEmpty ? '${ext.toUpperCase()} File' : 'Generic File';
        mimeType = 'application/octet-stream';
        confidence = 0.75;
        suggestedFolder = 'Downloads';
        explanation = 'Binary or non-standard file payload.';
        break;
    }

    return AIClassificationResult(
      category: category,
      confidence: confidence,
      fileType: fileType,
      suggestedFolder: suggestedFolder,
      mimeType: mimeType,
      explanation: explanation,
    );
  }
}
