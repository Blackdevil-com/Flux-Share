import '../models/file_info.dart';
import 'mock_data.dart';

class MockFileRepository {
  final List<FileInfo> _files = List.from(MockData.mockFiles);

  Future<List<FileInfo>> getAvailableFiles() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return List.unmodifiable(_files);
  }
}
