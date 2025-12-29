import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'mesh_enums.dart';

/// Represents a peer in the mesh network.
@immutable
class MeshPeer {
  /// Unique identifier for the peer.
  final String id;

  /// Display name of the peer.
  final String username;

  /// Transport type used to connect to this peer.
  final MeshTransportType transportType;

  /// Current connection state of the peer.
  final MeshPeerState state;

  /// IP address or transport-specific address of the peer.
  final String? address;

  /// Port number for the peer's transport.
  final int? port;

  /// Unix timestamp of last activity (milliseconds since epoch).
  final int lastSeenAt;

  /// Number of hops to reach this peer (0 = direct connection).
  final int hopCount;

  /// ID of the next-hop peer to reach this peer (null if direct).
  final String? nextHopPeerId;

  /// Additional metadata about the peer.
  final Map<String, dynamic> metadata;

  /// Creates a [MeshPeer] instance.
  const MeshPeer({
    required this.id,
    required this.username,
    required this.transportType,
    required this.state,
    this.address,
    this.port,
    required this.lastSeenAt,
    this.hopCount = 0,
    this.nextHopPeerId,
    this.metadata = const {},
  });

  /// Creates a [MeshPeer] from a JSON map.
  factory MeshPeer.fromJson(Map<String, dynamic> json) {
    return MeshPeer(
      id: json['id'] as String,
      username: json['username'] as String? ?? 'Unknown',
      transportType: MeshTransportType.values.firstWhere(
        (e) => e.name == json['transportType'],
        orElse: () => MeshTransportType.unknown,
      ),
      state: MeshPeerState.values.firstWhere(
        (e) => e.name == json['state'],
        orElse: () => MeshPeerState.discovered,
      ),
      address: json['address'] as String?,
      port: json['port'] as int?,
      lastSeenAt: json['lastSeenAt'] as int? ?? 0,
      hopCount: json['hopCount'] as int? ?? 0,
      nextHopPeerId: json['nextHopPeerId'] as String?,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  /// Converts this [MeshPeer] to a JSON map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'transportType': transportType.name,
    'state': state.name,
    'address': address,
    'port': port,
    'lastSeenAt': lastSeenAt,
    'hopCount': hopCount,
    'nextHopPeerId': nextHopPeerId,
    'metadata': metadata,
  };

  /// Creates a copy of this peer with updated fields.
  MeshPeer copyWith({
    String? id,
    String? username,
    MeshTransportType? transportType,
    MeshPeerState? state,
    String? address,
    int? port,
    int? lastSeenAt,
    int? hopCount,
    String? nextHopPeerId,
    Map<String, dynamic>? metadata,
  }) {
    return MeshPeer(
      id: id ?? this.id,
      username: username ?? this.username,
      transportType: transportType ?? this.transportType,
      state: state ?? this.state,
      address: address ?? this.address,
      port: port ?? this.port,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      hopCount: hopCount ?? this.hopCount,
      nextHopPeerId: nextHopPeerId ?? this.nextHopPeerId,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Returns `true` if this peer is directly connected (hop count 0).
  bool get isDirect => hopCount == 0;

  /// Returns `true` if this peer is currently active.
  bool get isActive =>
      state == MeshPeerState.connected || state == MeshPeerState.degraded;

  @override
  String toString() =>
      'MeshPeer(id: $id, username: $username, state: ${state.name}, hops: $hopCount)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshPeer && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Represents a message in the mesh network.
@immutable
class MeshMessage {
  /// Unique identifier for the message (for deduplication).
  final String id;

  /// Type of the message.
  final MeshMessageType type;

  /// ID of the peer that originated this message.
  final String sourceId;

  /// Username of the source peer.
  final String sourceUsername;

  /// Target peer IDs (empty for broadcast).
  final List<String> targetIds;

  /// Time-to-live (remaining hops).
  final int ttl;

  /// Unix timestamp when the message was created (milliseconds since epoch).
  final int createdAt;

  /// The message payload (type depends on [type]).
  final dynamic payload;

  /// Creates a [MeshMessage] instance.
  const MeshMessage({
    required this.id,
    required this.type,
    required this.sourceId,
    required this.sourceUsername,
    this.targetIds = const [],
    required this.ttl,
    required this.createdAt,
    this.payload,
  });

  /// Creates a new [MeshMessage] with a generated ID.
  factory MeshMessage.create({
    required MeshMessageType type,
    required String sourceId,
    required String sourceUsername,
    List<String> targetIds = const [],
    required int ttl,
    dynamic payload,
  }) {
    return MeshMessage(
      id: const Uuid().v4(),
      type: type,
      sourceId: sourceId,
      sourceUsername: sourceUsername,
      targetIds: targetIds,
      ttl: ttl,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    );
  }

  /// Creates a [MeshMessage] from a JSON map.
  factory MeshMessage.fromJson(Map<String, dynamic> json) {
    return MeshMessage(
      id: json['id'] as String,
      type: MeshMessageTypeExtension.fromJsonValue(json['type'] as String?),
      sourceId: json['sourceId'] as String,
      sourceUsername: json['sourceUsername'] as String? ?? 'Unknown',
      targetIds: List<String>.from(json['targetIds'] as List? ?? []),
      ttl: json['ttl'] as int? ?? 0,
      createdAt: json['createdAt'] as int? ?? 0,
      payload: json['payload'],
    );
  }

  /// Creates a [MeshMessage] from a JSON string.
  factory MeshMessage.fromJsonString(String jsonString) {
    return MeshMessage.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }

  /// Converts this [MeshMessage] to a JSON map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.toJsonValue(),
    'sourceId': sourceId,
    'sourceUsername': sourceUsername,
    'targetIds': targetIds,
    'ttl': ttl,
    'createdAt': createdAt,
    'payload': payload,
  };

  /// Converts this [MeshMessage] to a JSON string.
  String toJsonString() => jsonEncode(toJson());

  /// Creates a copy with decremented TTL for forwarding.
  MeshMessage forForwarding() {
    return MeshMessage(
      id: id,
      type: type,
      sourceId: sourceId,
      sourceUsername: sourceUsername,
      targetIds: targetIds,
      ttl: ttl - 1,
      createdAt: createdAt,
      payload: payload,
    );
  }

  /// Returns `true` if this message is a broadcast (no specific targets).
  bool get isBroadcast => targetIds.isEmpty;

  /// Returns `true` if this message should still be forwarded.
  bool get canForward => ttl > 0;

  @override
  String toString() =>
      'MeshMessage(id: $id, type: ${type.name}, from: $sourceId, ttl: $ttl)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Represents the payload for a data message.
@immutable
class MeshDataPayload {
  /// Text content of the message.
  final String text;

  /// List of file announcements included in the message.
  final List<MeshFileInfo> files;

  /// Custom data map for application-specific payloads.
  final Map<String, dynamic> customData;

  /// Creates a [MeshDataPayload] instance.
  const MeshDataPayload({
    this.text = '',
    this.files = const [],
    this.customData = const {},
  });

  /// Creates a [MeshDataPayload] from a JSON map.
  factory MeshDataPayload.fromJson(Map<String, dynamic> json) {
    return MeshDataPayload(
      text: json['text'] as String? ?? '',
      files: (json['files'] as List? ?? [])
          .map((f) => MeshFileInfo.fromJson(f as Map<String, dynamic>))
          .toList(),
      customData: Map<String, dynamic>.from(json['customData'] as Map? ?? {}),
    );
  }

  /// Converts this [MeshDataPayload] to a JSON map.
  Map<String, dynamic> toJson() => {
    'text': text,
    'files': files.map((f) => f.toJson()).toList(),
    'customData': customData,
  };

  @override
  String toString() =>
      'MeshDataPayload(text: "${text.length > 30 ? '${text.substring(0, 27)}...' : text}", files: ${files.length})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshDataPayload &&
          runtimeType == other.runtimeType &&
          text == other.text &&
          listEquals(files, other.files) &&
          mapEquals(customData, other.customData);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(files), customData);
}

/// Represents metadata for a file available in the mesh network.
@immutable
class MeshFileInfo {
  /// Unique identifier for the file.
  final String id;

  /// Name of the file.
  final String name;

  /// Size of the file in bytes.
  final int size;

  /// MIME type of the file.
  final String mimeType;

  /// SHA-256 hash of the file for integrity verification.
  final String? sha256;

  /// ID of the peer hosting the file.
  final String hostPeerId;

  /// Chunk size used for transfer.
  final int chunkSize;

  /// Total number of chunks.
  final int totalChunks;

  /// Additional metadata (e.g., thumbnail, dimensions for images).
  final Map<String, dynamic> metadata;

  /// Creates a [MeshFileInfo] instance.
  const MeshFileInfo({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType = 'application/octet-stream',
    this.sha256,
    required this.hostPeerId,
    this.chunkSize = 65536,
    required this.totalChunks,
    this.metadata = const {},
  });

  /// Creates a [MeshFileInfo] from a JSON map.
  factory MeshFileInfo.fromJson(Map<String, dynamic> json) {
    return MeshFileInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sha256: json['sha256'] as String?,
      hostPeerId: json['hostPeerId'] as String,
      chunkSize: json['chunkSize'] as int? ?? 65536,
      totalChunks: json['totalChunks'] as int,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  /// Converts this [MeshFileInfo] to a JSON map.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'mimeType': mimeType,
    'sha256': sha256,
    'hostPeerId': hostPeerId,
    'chunkSize': chunkSize,
    'totalChunks': totalChunks,
    'metadata': metadata,
  };

  @override
  String toString() =>
      'MeshFileInfo(id: $id, name: $name, size: $size, host: $hostPeerId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshFileInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Represents a file chunk being transferred.
@immutable
class MeshFileChunk {
  /// ID of the file this chunk belongs to.
  final String fileId;

  /// Index of this chunk (0-based).
  final int chunkIndex;

  /// CRC32 checksum of the chunk data.
  final int crc32;

  /// The chunk data (base64 encoded when serialized).
  final Uint8List data;

  /// Creates a [MeshFileChunk] instance.
  const MeshFileChunk({
    required this.fileId,
    required this.chunkIndex,
    required this.crc32,
    required this.data,
  });

  /// Creates a [MeshFileChunk] from a JSON map.
  factory MeshFileChunk.fromJson(Map<String, dynamic> json) {
    return MeshFileChunk(
      fileId: json['fileId'] as String,
      chunkIndex: json['chunkIndex'] as int,
      crc32: json['crc32'] as int,
      data: base64Decode(json['data'] as String),
    );
  }

  /// Converts this [MeshFileChunk] to a JSON map.
  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'chunkIndex': chunkIndex,
    'crc32': crc32,
    'data': base64Encode(data),
  };

  @override
  String toString() =>
      'MeshFileChunk(fileId: $fileId, index: $chunkIndex, size: ${data.length})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshFileChunk &&
          runtimeType == other.runtimeType &&
          fileId == other.fileId &&
          chunkIndex == other.chunkIndex;

  @override
  int get hashCode => Object.hash(fileId, chunkIndex);
}

/// Represents the progress of a file transfer.
@immutable
class MeshFileTransferProgress {
  /// ID of the file being transferred.
  final String fileId;

  /// Name of the file.
  final String fileName;

  /// Total size in bytes.
  final int totalSize;

  /// Bytes transferred so far.
  final int transferredBytes;

  /// Number of chunks received.
  final int chunksReceived;

  /// Total number of chunks.
  final int totalChunks;

  /// Current transfer state.
  final MeshFileTransferState state;

  /// Error message if state is [MeshFileTransferState.failed].
  final String? errorMessage;

  /// Creates a [MeshFileTransferProgress] instance.
  const MeshFileTransferProgress({
    required this.fileId,
    required this.fileName,
    required this.totalSize,
    required this.transferredBytes,
    required this.chunksReceived,
    required this.totalChunks,
    required this.state,
    this.errorMessage,
  });

  /// Progress as a value between 0.0 and 1.0.
  double get progress => totalChunks > 0 ? chunksReceived / totalChunks : 0.0;

  /// Progress as a percentage (0-100).
  int get progressPercent => (progress * 100).round();

  @override
  String toString() =>
      'MeshFileTransferProgress(file: $fileName, $progressPercent%, state: ${state.name})';
}

/// Represents a peer announcement payload.
@immutable
class MeshPeerAnnounce {
  /// The announcing peer's information.
  final MeshPeer peer;

  /// List of peers known to the announcing peer (for sync).
  final List<MeshPeer> knownPeers;

  /// Creates a [MeshPeerAnnounce] instance.
  const MeshPeerAnnounce({required this.peer, this.knownPeers = const []});

  /// Creates a [MeshPeerAnnounce] from a JSON map.
  factory MeshPeerAnnounce.fromJson(Map<String, dynamic> json) {
    return MeshPeerAnnounce(
      peer: MeshPeer.fromJson(json['peer'] as Map<String, dynamic>),
      knownPeers: (json['knownPeers'] as List? ?? [])
          .map((p) => MeshPeer.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Converts this [MeshPeerAnnounce] to a JSON map.
  Map<String, dynamic> toJson() => {
    'peer': peer.toJson(),
    'knownPeers': knownPeers.map((p) => p.toJson()).toList(),
  };

  @override
  String toString() =>
      'MeshPeerAnnounce(peer: ${peer.username}, knows: ${knownPeers.length} peers)';
}
