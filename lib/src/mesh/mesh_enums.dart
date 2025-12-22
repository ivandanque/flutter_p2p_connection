/// Enum representing the type of a mesh message.
enum MeshMessageType {
  /// A data payload (text, files, or custom data).
  data,

  /// Peer discovery announcement (broadcast).
  peerAnnounce,

  /// Peer list synchronization.
  peerSync,

  /// Request for routing information.
  routeRequest,

  /// Response with routing information.
  routeResponse,

  /// Acknowledgment of received message.
  ack,

  /// File transfer metadata announcement.
  fileAnnounce,

  /// File chunk data.
  fileChunk,

  /// File chunk acknowledgment.
  fileChunkAck,

  /// File transfer completion.
  fileComplete,

  /// Ping to check peer liveness.
  ping,

  /// Pong response to ping.
  pong,

  /// Unknown or unsupported message type.
  unknown,
}

/// Extension to convert [MeshMessageType] to/from string.
extension MeshMessageTypeExtension on MeshMessageType {
  /// Converts enum value to string for serialization.
  String toJsonValue() => name;

  /// Creates enum value from string.
  static MeshMessageType fromJsonValue(String? value) {
    if (value == null) return MeshMessageType.unknown;
    return MeshMessageType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => MeshMessageType.unknown,
    );
  }
}

/// Enum representing the state of a mesh peer connection.
enum MeshPeerState {
  /// Peer discovered but not yet connected.
  discovered,

  /// Connection attempt in progress.
  connecting,

  /// Peer is connected and active.
  connected,

  /// Peer connection is degraded (high latency, packet loss).
  degraded,

  /// Peer is disconnected.
  disconnected,

  /// Peer is stale (no activity for extended period).
  stale,
}

/// Enum representing the transport type used to connect to a peer.
enum MeshTransportType {
  /// Wi-Fi Aware (NAN) transport.
  wifiAware,

  /// Wi-Fi Direct transport.
  wifiDirect,

  /// Bluetooth LE transport.
  ble,

  /// Local network (mDNS/TCP) transport.
  lan,

  /// WebRTC data channel transport.
  webRtc,

  /// Unknown transport.
  unknown,
}

/// Enum representing file transfer state.
enum MeshFileTransferState {
  /// Transfer is pending/queued.
  pending,

  /// Transfer metadata sent, waiting for chunks.
  announced,

  /// Transfer is in progress.
  transferring,

  /// Transfer is paused.
  paused,

  /// Transfer completed successfully.
  completed,

  /// Transfer failed.
  failed,

  /// Transfer was cancelled.
  cancelled,
}
