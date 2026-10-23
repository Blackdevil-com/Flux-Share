import '../models/models.dart';

class MockData {
  static final List<Device> mockDevices = [
    const Device(
      id: 'dev_1',
      name: "Akash's iPhone",
      platform: DevicePlatform.iPhone,
      isAvailable: true,
      signalStrength: 4,
    ),
    const Device(
      id: 'dev_2',
      name: "Rohan's Android",
      platform: DevicePlatform.Android,
      isAvailable: true,
      signalStrength: 3,
    ),
    const Device(
      id: 'dev_3',
      name: "Dev's Tablet",
      platform: DevicePlatform.Android,
      isAvailable: true,
      signalStrength: 4,
    ),
    const Device(
      id: 'dev_4',
      name: "Office Laptop",
      platform: DevicePlatform.Windows,
      isAvailable: false,
      signalStrength: 2,
    ),
    const Device(
      id: 'dev_5',
      name: "Sneha's Phone",
      platform: DevicePlatform.iPhone,
      isAvailable: true,
      signalStrength: 3,
    ),
  ];

  static final List<FileInfo> mockFiles = [
    const FileInfo(
      id: 'file_1',
      name: 'Project_Video.mp4',
      sizeBytes: 5153960755, // 4.8 GB
      formattedSize: '4.8 GB',
      extension: 'mp4',
      type: FileType.Video,
    ),
    const FileInfo(
      id: 'file_2',
      name: 'Project_Report.pdf',
      sizeBytes: 2576980377, // 2.4 GB
      formattedSize: '2.4 GB',
      extension: 'pdf',
      type: FileType.Document,
    ),
    const FileInfo(
      id: 'file_3',
      name: 'Photos.zip',
      sizeBytes: 1288490188, // 1.2 GB
      formattedSize: '1.2 GB',
      extension: 'zip',
      type: FileType.Archive,
    ),
    const FileInfo(
      id: 'file_4',
      name: 'Presentation.pptx',
      sizeBytes: 335544320, // 320 MB
      formattedSize: '320 MB',
      extension: 'pptx',
      type: FileType.Presentation,
    ),
  ];

  static final List<Transfer> initialTransfers = [
    Transfer(
      id: 'trans_1',
      fileInfo: mockFiles[0], // Project_Video.mp4
      direction: TransferDirection.sent,
      status: TransferStatus.transferring,
      progressPercent: 45.0,
      bytesTransferred: 2319282339,
      transferSpeedMbPerSec: 28.5,
      remainingSeconds: 98,
      timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Akash's iPhone",
          devicePlatform: DevicePlatform.iPhone,
          progressPercent: 45.0,
        ),
        ReceiverProgress(
          deviceName: "Rohan's Android",
          devicePlatform: DevicePlatform.Android,
          progressPercent: 40.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 100,
        'completedChunks': 45,
        'failedChunks': 0,
        'activePeers': 2,
      },
    ),
    Transfer(
      id: 'trans_2',
      fileInfo: mockFiles[1], // Project_Report.pdf
      direction: TransferDirection.received,
      status: TransferStatus.paused,
      progressPercent: 62.0,
      bytesTransferred: 1597727833,
      transferSpeedMbPerSec: 0.0,
      remainingSeconds: 45,
      timestamp: DateTime.now().subtract(const Duration(minutes: 20)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Office Laptop",
          devicePlatform: DevicePlatform.Windows,
          progressPercent: 62.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 50,
        'completedChunks': 31,
        'failedChunks': 0,
        'activePeers': 1,
      },
    ),
    Transfer(
      id: 'trans_3',
      fileInfo: mockFiles[2], // Photos.zip
      direction: TransferDirection.sent,
      status: TransferStatus.completed,
      progressPercent: 100.0,
      bytesTransferred: 1288490188,
      transferSpeedMbPerSec: 35.0,
      remainingSeconds: 0,
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Sneha's Phone",
          devicePlatform: DevicePlatform.iPhone,
          progressPercent: 100.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 40,
        'completedChunks': 40,
        'failedChunks': 0,
        'activePeers': 0,
      },
    ),
    Transfer(
      id: 'trans_4',
      fileInfo: mockFiles[3], // Presentation.pptx
      direction: TransferDirection.received,
      status: TransferStatus.completed,
      progressPercent: 100.0,
      bytesTransferred: 335544320,
      transferSpeedMbPerSec: 42.0,
      remainingSeconds: 0,
      timestamp: DateTime.now().subtract(const Duration(days: 1)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Dev's Tablet",
          devicePlatform: DevicePlatform.Android,
          progressPercent: 100.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 20,
        'completedChunks': 20,
        'failedChunks': 0,
        'activePeers': 0,
      },
    ),
    Transfer(
      id: 'trans_5',
      fileInfo: const FileInfo(
        id: 'file_5',
        name: 'Database_Backup.sql',
        sizeBytes: 838860800, // 800 MB
        formattedSize: '800 MB',
        extension: 'sql',
        type: FileType.Document,
      ),
      direction: TransferDirection.received,
      status: TransferStatus.failed,
      progressPercent: 15.0,
      bytesTransferred: 125829120,
      transferSpeedMbPerSec: 0.0,
      remainingSeconds: 0,
      timestamp: DateTime.now().subtract(const Duration(hours: 4)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Office Laptop",
          devicePlatform: DevicePlatform.Windows,
          progressPercent: 15.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 80,
        'completedChunks': 12,
        'failedChunks': 5,
        'activePeers': 0,
      },
    ),
    Transfer(
      id: 'trans_6',
      fileInfo: const FileInfo(
        id: 'file_6',
        name: 'Dataset.csv',
        sizeBytes: 157286400, // 150 MB
        formattedSize: '150 MB',
        extension: 'csv',
        type: FileType.Document,
      ),
      direction: TransferDirection.sent,
      status: TransferStatus.cancelled,
      progressPercent: 50.0,
      bytesTransferred: 78643200,
      transferSpeedMbPerSec: 0.0,
      remainingSeconds: 0,
      timestamp: DateTime.now().subtract(const Duration(days: 2)),
      receivers: const [
        ReceiverProgress(
          deviceName: "Rohan's Android",
          devicePlatform: DevicePlatform.Android,
          progressPercent: 50.0,
        ),
      ],
      chunkStats: const {
        'totalChunks': 30,
        'completedChunks': 15,
        'failedChunks': 0,
        'activePeers': 0,
      },
    ),
  ];
}
