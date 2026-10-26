/// Strongly-typed error classification for chunk and file transfer failures.
enum TransferFailureReason {
  connectionRefused,
  timeoutConnection,
  timeoutHeaders,
  timeoutBody,
  notFound,
  httpError,
  lengthMismatch,
  sha256Mismatch,
  diskWriteFailure,
  diskSpaceInsufficient,
  cancelled,
  retriesExhausted,
  unknown;

  /// User-friendly, actionable diagnostic message for UI display.
  String toUserMessage() {
    switch (this) {
      case TransferFailureReason.connectionRefused:
        return 'Connection lost. Waiting to reconnect…';
      case TransferFailureReason.timeoutConnection:
        return 'Reconnecting to sender…';
      case TransferFailureReason.timeoutHeaders:
        return 'Sender response delayed. Retrying…';
      case TransferFailureReason.timeoutBody:
        return 'Download stream stalled. Retrying…';
      case TransferFailureReason.notFound:
        return 'File or chunk not found on sender.';
      case TransferFailureReason.httpError:
        return 'Sender returned error.';
      case TransferFailureReason.lengthMismatch:
        return 'Chunk data incomplete. Retrying…';
      case TransferFailureReason.sha256Mismatch:
        return 'Chunk verification failed. Retrying…';
      case TransferFailureReason.diskWriteFailure:
        return 'Failed to save to device storage.';
      case TransferFailureReason.diskSpaceInsufficient:
        return 'Not enough storage space to continue.';
      case TransferFailureReason.cancelled:
        return 'Transfer cancelled.';
      case TransferFailureReason.retriesExhausted:
        return 'Transfer failed: sender is no longer available.';
      case TransferFailureReason.unknown:
        return 'Transfer error encountered.';
    }
  }

  /// Whether this failure is transient and can be retried automatically.
  bool get isTransient {
    switch (this) {
      case TransferFailureReason.timeoutConnection:
      case TransferFailureReason.timeoutHeaders:
      case TransferFailureReason.timeoutBody:
      case TransferFailureReason.lengthMismatch:
      case TransferFailureReason.sha256Mismatch:
        return true;
      case TransferFailureReason.connectionRefused:
      case TransferFailureReason.notFound:
      case TransferFailureReason.httpError:
      case TransferFailureReason.diskWriteFailure:
      case TransferFailureReason.diskSpaceInsufficient:
      case TransferFailureReason.cancelled:
      case TransferFailureReason.retriesExhausted:
      case TransferFailureReason.unknown:
        return false;
    }
  }
}
