/// Exception thrown when a mesh operation is attempted before initialization.
class MeshNotInitializedException implements Exception {
  /// Descriptive error message.
  final String message;

  /// Creates a [MeshNotInitializedException].
  const MeshNotInitializedException([
    this.message = 'Mesh node is not initialized. Call start() first.',
  ]);

  @override
  String toString() => 'MeshNotInitializedException: $message';
}

/// Exception thrown when a peer is not found in the mesh network.
class MeshPeerNotFoundException implements Exception {
  /// The ID of the peer that was not found.
  final String peerId;

  /// Descriptive error message.
  final String message;

  /// Creates a [MeshPeerNotFoundException].
  const MeshPeerNotFoundException(
    this.peerId, [
    this.message = 'Peer not found in mesh network.',
  ]);

  @override
  String toString() => 'MeshPeerNotFoundException: $message (peerId: $peerId)';
}

/// Exception thrown when a message cannot be routed.
class MeshRoutingException implements Exception {
  /// The ID of the message that could not be routed.
  final String? messageId;

  /// Descriptive error message.
  final String message;

  /// Creates a [MeshRoutingException].
  const MeshRoutingException(this.message, [this.messageId]);

  @override
  String toString() =>
      'MeshRoutingException: $message${messageId != null ? ' (messageId: $messageId)' : ''}';
}

/// Exception thrown when a file transfer fails.
class MeshFileTransferException implements Exception {
  /// The ID of the file transfer that failed.
  final String? fileId;

  /// Descriptive error message.
  final String message;

  /// Creates a [MeshFileTransferException].
  const MeshFileTransferException(this.message, [this.fileId]);

  @override
  String toString() =>
      'MeshFileTransferException: $message${fileId != null ? ' (fileId: $fileId)' : ''}';
}

/// Exception thrown when transport adapter operations fail.
class MeshTransportException implements Exception {
  /// Descriptive error message.
  final String message;

  /// The underlying error, if any.
  final Object? cause;

  /// Creates a [MeshTransportException].
  const MeshTransportException(this.message, [this.cause]);

  @override
  String toString() =>
      'MeshTransportException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// Exception thrown when Wi-Fi Aware is not supported or available.
class WifiAwareNotSupportedException implements Exception {
  /// Descriptive error message.
  final String message;

  /// Creates a [WifiAwareNotSupportedException].
  const WifiAwareNotSupportedException([
    this.message =
        'Wi-Fi Aware is not supported or not available on this device.',
  ]);

  @override
  String toString() => 'WifiAwareNotSupportedException: $message';
}
