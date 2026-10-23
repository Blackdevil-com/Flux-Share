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

  static Future<FileInfo> fromFile(File file) async {
    final name = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'file';
    final length = await file.length();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

    String formatted;
    if (length < 1024) {
      formatted = '$length B';
    } else if (length < 1024 * 1024) {
      formatted = '${(length / 1024).toStringAsFixed(1)} KB';
    } else if (length < 1024 * 1024 * 1024) {
      formatted = '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      formatted = '${(length / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }

    FileType type;
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(ext)) {
      type = FileType.Video;
    } else if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
      type = FileType.Image;
    } else if (['pdf', 'doc', 'docx', 'txt', 'rtf'].contains(ext)) {
      type = FileType.Document;
    } else if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      type = FileType.Archive;
    } else if (['ppt', 'pptx'].contains(ext)) {
      type = FileType.Presentation;
    } else {
      type = FileType.Other;
    }

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
