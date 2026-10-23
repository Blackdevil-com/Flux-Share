import '../models/models.dart';
import 'ai_models.dart';

/// Natural-language file search engine converting conversational queries into
/// structured local filters. Evaluates strictly against local metadata without
/// ever uploading filenames or file contents to external services.
class SmartFileSearch {
  /// Parses conversational input into a structured metadata query.
  StructuredFileFilter parseQuery(String query) {
    final lower = query.toLowerCase().trim();

    AIFileCategory? category;
    int? minSizeBytes;
    int? maxSizeBytes;
    String? dateRange;
    String? peerSender;

    // 1. Detect Category
    if (lower.contains('video') || lower.contains('movie') || lower.contains('mp4')) {
      category = AIFileCategory.videos;
    } else if (lower.contains('photo') || lower.contains('image') || lower.contains('picture') || lower.contains('jpg') || lower.contains('png')) {
      category = AIFileCategory.images;
    } else if (lower.contains('music') || lower.contains('song') || lower.contains('audio') || lower.contains('mp3')) {
      category = AIFileCategory.audio;
    } else if (lower.contains('pdf')) {
      category = AIFileCategory.pdfs;
    } else if (lower.contains('presentation') || lower.contains('ppt') || lower.contains('slide')) {
      category = AIFileCategory.presentations;
    } else if (lower.contains('spreadsheet') || lower.contains('excel') || lower.contains('sheet') || lower.contains('csv')) {
      category = AIFileCategory.spreadsheets;
    } else if (lower.contains('document') || lower.contains('doc') || lower.contains('text') || lower.contains('txt')) {
      category = AIFileCategory.documents;
    } else if (lower.contains('archive') || lower.contains('zip') || lower.contains('compressed')) {
      category = AIFileCategory.archives;
    } else if (lower.contains('code') || lower.contains('source') || lower.contains('script')) {
      category = AIFileCategory.code;
    }

    // 2. Detect Size Constraints
    final largerRegex = RegExp(r'(?:larger than|greater than|over|more than|>)\s*(\d+(?:\.\d+)?)\s*(gb|mb|kb|b)?');
    final largerMatch = largerRegex.firstMatch(lower);
    if (largerMatch != null) {
      final val = double.tryParse(largerMatch.group(1) ?? '') ?? 0.0;
      final unit = (largerMatch.group(2) ?? 'mb').toLowerCase();
      minSizeBytes = _parseBytes(val, unit);
    }

    final smallerRegex = RegExp(r'(?:smaller than|less than|under|<)\s*(\d+(?:\.\d+)?)\s*(gb|mb|kb|b)?');
    final smallerMatch = smallerRegex.firstMatch(lower);
    if (smallerMatch != null) {
      final val = double.tryParse(smallerMatch.group(1) ?? '') ?? 0.0;
      final unit = (smallerMatch.group(2) ?? 'mb').toLowerCase();
      maxSizeBytes = _parseBytes(val, unit);
    }

    // 3. Detect Temporal Constraints
    if (lower.contains('today')) {
      dateRange = 'today';
    } else if (lower.contains('yesterday')) {
      dateRange = 'yesterday';
    } else if (lower.contains('this week') || lower.contains('past week') || lower.contains('last 7 days')) {
      dateRange = 'this_week';
    } else if (lower.contains('this month')) {
      dateRange = 'this_month';
    }

    // 4. Detect Peer / Sender Constraint
    final fromRegex = RegExp(r"(?:from|received from)\s+([a-zA-Z0-9_\-'\s]+)");
    final fromMatch = fromRegex.firstMatch(lower);
    if (fromMatch != null) {
      var name = fromMatch.group(1)?.trim() ?? '';
      name = name
          .replaceAll(
            RegExp(r'\s+(today|yesterday|this week|past week|last 7 days|this month|larger.*|smaller.*)$'),
            '',
          )
          .trim();
      if (name.isNotEmpty) {
        peerSender = name;
      }
    }

    return StructuredFileFilter(
      category: category,
      minSizeBytes: minSizeBytes,
      maxSizeBytes: maxSizeBytes,
      dateRange: dateRange,
      peerSender: peerSender,
      rawQuery: query,
    );
  }

  /// Executes structured query over a collection of Transfer records.
  List<Transfer> searchTransfers({
    required String query,
    required List<Transfer> transfers,
  }) {
    if (query.trim().isEmpty) return transfers;

    final filter = parseQuery(query);
    final now = DateTime.now();

    final results = transfers.where((t) {
      // 1. Category filter
      if (filter.category != null) {
        final ext = t.fileInfo.extension.toLowerCase();
        final matches = _matchesCategory(ext, filter.category!);
        if (!matches) return false;
      }

      // 2. Min size filter
      if (filter.minSizeBytes != null && t.fileInfo.sizeBytes < filter.minSizeBytes!) {
        return false;
      }

      // 3. Max size filter
      if (filter.maxSizeBytes != null && t.fileInfo.sizeBytes > filter.maxSizeBytes!) {
        return false;
      }

      // 4. Date range filter
      if (filter.dateRange != null) {
        final diff = now.difference(t.timestamp);
        switch (filter.dateRange) {
          case 'today':
            final sameDay = now.year == t.timestamp.year &&
                now.month == t.timestamp.month &&
                now.day == t.timestamp.day;
            if (!sameDay) return false;
            break;
          case 'yesterday':
            final yesterday = now.subtract(const Duration(days: 1));
            final sameDay = yesterday.year == t.timestamp.year &&
                yesterday.month == t.timestamp.month &&
                yesterday.day == t.timestamp.day;
            if (!sameDay) return false;
            break;
          case 'this_week':
            if (diff.inDays > 7) return false;
            break;
          case 'this_month':
            if (diff.inDays > 31) return false;
            break;
        }
      }

      // 5. Peer sender filter
      if (filter.peerSender != null && filter.peerSender!.isNotEmpty) {
        final senderQuery = filter.peerSender!.toLowerCase();
        final matchesReceiver = t.receivers.any((r) =>
            r.deviceName.toLowerCase().contains(senderQuery) ||
            (r.peerId?.toLowerCase().contains(senderQuery) ?? false));
        if (!matchesReceiver && !t.fileInfo.name.toLowerCase().contains(senderQuery)) {
          return false;
        }
      }

      // 6. Generic substring matching if no structured filter triggered
      if (filter.category == null &&
          filter.minSizeBytes == null &&
          filter.maxSizeBytes == null &&
          filter.dateRange == null &&
          filter.peerSender == null) {
        const stopWords = {
          'find',
          'show',
          'the',
          'largest',
          'biggest',
          'smallest',
          'files',
          'file',
          'transfers',
          'all',
          'get',
          'list',
        };
        final queryWords = query
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 2 && !stopWords.contains(w));
        for (final word in queryWords) {
          if (!t.fileInfo.name.toLowerCase().contains(word)) {
            return false;
          }
        }
      }

      return true;
    }).toList();

    // Sort by largest if asked
    if (query.toLowerCase().contains('largest') || query.toLowerCase().contains('biggest')) {
      results.sort((a, b) => b.fileInfo.sizeBytes.compareTo(a.fileInfo.sizeBytes));
    }

    return results;
  }

  static bool _matchesCategory(String ext, AIFileCategory category) {
    switch (category) {
      case AIFileCategory.images:
        return ['jpg', 'jpeg', 'png', 'webp', 'gif', 'svg', 'heic', 'bmp'].contains(ext);
      case AIFileCategory.videos:
        return ['mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'wmv'].contains(ext);
      case AIFileCategory.audio:
        return ['mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus'].contains(ext);
      case AIFileCategory.pdfs:
        return ext == 'pdf';
      case AIFileCategory.presentations:
        return ['ppt', 'pptx', 'odp', 'key'].contains(ext);
      case AIFileCategory.spreadsheets:
        return ['xls', 'xlsx', 'ods', 'csv', 'tsv'].contains(ext);
      case AIFileCategory.documents:
        return ['doc', 'docx', 'txt', 'rtf', 'odt', 'md'].contains(ext);
      case AIFileCategory.archives:
        return ['zip', 'rar', '7z', 'tar', 'gz', 'apk', 'iso'].contains(ext);
      case AIFileCategory.code:
        return ['dart', 'kt', 'java', 'py', 'js', 'ts', 'html', 'css', 'c', 'cpp', 'cs', 'go', 'rs', 'swift', 'json', 'yaml', 'xml'].contains(ext);
      case AIFileCategory.other:
        return true;
    }
  }

  static int _parseBytes(double value, String unit) {
    switch (unit) {
      case 'gb':
        return (value * 1024 * 1024 * 1024).round();
      case 'mb':
        return (value * 1024 * 1024).round();
      case 'kb':
        return (value * 1024).round();
      case 'b':
      default:
        return value.round();
    }
  }
}
