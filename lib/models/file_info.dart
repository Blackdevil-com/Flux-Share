import 'dart:io';

enum FileType {
  Video,
  Document,
  Archive,
  Presentation,
  Image,
  Other;

  String get displayName {
    switch (this) {
      case FileType.Video:
        return 'Video';
      case FileType.Document:
        return 'Document';
      case FileType.Archive:
        return 'Archive';
      case FileType.Presentation:
        return 'Presentation';
      case FileType.Image:
        return 'Image';
      case FileType.Other:
        return 'Other';
    }
  }

  static FileType fromString(String val) {
    switch (val.toLowerCase()) {
      case 'video':
        return FileType.Video;
      case 'document':
      case 'pdf':
        return FileType.Document;
      case 'archive':
      case 'zip':
        return FileType.Archive;
      case 'presentation':
      case 'pptx':
        return FileType.Presentation;
      case 'image':
        return FileType.Image;
      default:
        return FileType.Other;
    }
  }
}

class FileInfo {
  final String id;
  final String name;
  final int sizeBytes;
  final String formattedSize;
  final String extension;
  final FileType type;

  const FileInfo({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.formattedSize,
    required this.extension,
    required this.type,
  });

  static String formatBytes(int length) {
    if (length < 1024) {
      return '$length B';
    } else if (length < 1024 * 1024) {
      return '${(length / 1024).toStringAsFixed(1)} KB';
    } else if (length < 1024 * 1024 * 1024) {
      return '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(length / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  static FileType detectFileType(String ext) {
    final lower = ext.toLowerCase();
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(lower)) {
      return FileType.Video;
    } else if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(lower)) {
      return FileType.Image;
    } else if (['pdf', 'doc', 'docx', 'txt', 'rtf'].contains(lower)) {
      return FileType.Document;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(lower)) {
      return FileType.Archive;
    } else if (['ppt', 'pptx'].contains(lower)) {
      return FileType.Presentation;
    } else {
      return FileType.Other;
    }
  }

  factory FileInfo.fromMetadata({
    required String path,
    required String name,
    required int sizeBytes,
    String? extension,
    FileType? type,
  }) {
    final ext = extension ?? (name.contains('.') ? name.split('.').last.toLowerCase() : '');
    final resolvedType = type ?? detectFileType(ext);
    return FileInfo(
      id: path,
      name: name,
      sizeBytes: sizeBytes,
      formattedSize: formatBytes(sizeBytes),
      extension: ext,
      type: resolvedType,
    );
  }

  static Future<FileInfo> fromFile(File file) async {
    final name = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'file';
    final length = await file.length();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final formatted = formatBytes(length);
    final type = detectFileType(ext);

    return FileInfo(
      id: file.path,
      name: name,
      sizeBytes: length,
      formattedSize: formatted,
      extension: ext,
      type: type,
    );
  }

  FileInfo copyWith({
    String? id,
    String? name,
    int? sizeBytes,
    String? formattedSize,
    String? extension,
    FileType? type,
  }) {
    return FileInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      formattedSize: formattedSize ?? this.formattedSize,
      extension: extension ?? this.extension,
      type: type ?? this.type,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'sizeBytes': sizeBytes,
      'formattedSize': formattedSize,
      'extension': extension,
      'type': type.displayName,
    };
  }

  factory FileInfo.fromMap(Map<String, dynamic> map) {
    return FileInfo(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      sizeBytes: map['sizeBytes'] ?? 0,
      formattedSize: map['formattedSize'] ?? '',
      extension: map['extension'] ?? '',
      type: FileType.fromString(map['type'] ?? ''),
    );
  }
}
