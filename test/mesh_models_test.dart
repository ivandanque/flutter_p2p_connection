import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_p2p_connection/src/mesh/mesh_enums.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_models.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_constants.dart';

void main() {
  group('MeshPeer', () {
    test('should create from JSON', () {
      final json = {
        'id': 'peer-123',
        'username': 'Alice',
        'transportType': 'wifiAware',
        'state': 'connected',
        'address': '192.168.1.100',
        'port': 5678,
        'lastSeenAt': 1702742400000,
        'hopCount': 0,
        'nextHopPeerId': null,
        'metadata': {'customKey': 'customValue'},
      };

      final peer = MeshPeer.fromJson(json);

      expect(peer.id, 'peer-123');
      expect(peer.username, 'Alice');
      expect(peer.transportType, MeshTransportType.wifiAware);
      expect(peer.state, MeshPeerState.connected);
      expect(peer.address, '192.168.1.100');
      expect(peer.port, 5678);
      expect(peer.hopCount, 0);
      expect(peer.isDirect, isTrue);
      expect(peer.isActive, isTrue);
      expect(peer.metadata['customKey'], 'customValue');
    });

    test('should serialize to JSON', () {
      const peer = MeshPeer(
        id: 'peer-456',
        username: 'Bob',
        transportType: MeshTransportType.wifiDirect,
        state: MeshPeerState.discovered,
        lastSeenAt: 1702742400000,
        hopCount: 2,
        nextHopPeerId: 'peer-789',
      );

      final json = peer.toJson();

      expect(json['id'], 'peer-456');
      expect(json['username'], 'Bob');
      expect(json['transportType'], 'wifiDirect');
      expect(json['state'], 'discovered');
      expect(json['hopCount'], 2);
      expect(json['nextHopPeerId'], 'peer-789');
    });

    test('should copy with updated fields', () {
      const peer = MeshPeer(
        id: 'peer-123',
        username: 'Alice',
        transportType: MeshTransportType.wifiAware,
        state: MeshPeerState.discovered,
        lastSeenAt: 1702742400000,
      );

      final updatedPeer = peer.copyWith(
        state: MeshPeerState.connected,
        hopCount: 1,
      );

      expect(updatedPeer.id, 'peer-123');
      expect(updatedPeer.username, 'Alice');
      expect(updatedPeer.state, MeshPeerState.connected);
      expect(updatedPeer.hopCount, 1);
    });

    test('should check equality by ID', () {
      const peer1 = MeshPeer(
        id: 'peer-123',
        username: 'Alice',
        transportType: MeshTransportType.wifiAware,
        state: MeshPeerState.connected,
        lastSeenAt: 1702742400000,
      );

      const peer2 = MeshPeer(
        id: 'peer-123',
        username: 'Alice Updated',
        transportType: MeshTransportType.wifiDirect,
        state: MeshPeerState.disconnected,
        lastSeenAt: 1702742500000,
      );

      expect(peer1, equals(peer2)); // Same ID
    });
  });

  group('MeshMessage', () {
    test('should create with generated ID', () {
      final message = MeshMessage.create(
        type: MeshMessageType.data,
        sourceId: 'source-123',
        sourceUsername: 'Alice',
        ttl: defaultMeshTtl,
        payload: const {'text': 'Hello'},
      );

      expect(message.id, isNotEmpty);
      expect(message.type, MeshMessageType.data);
      expect(message.sourceId, 'source-123');
      expect(message.sourceUsername, 'Alice');
      expect(message.ttl, defaultMeshTtl);
      expect(message.isBroadcast, isTrue);
      expect(message.canForward, isTrue);
    });

    test('should create targeted message', () {
      final message = MeshMessage.create(
        type: MeshMessageType.data,
        sourceId: 'source-123',
        sourceUsername: 'Alice',
        targetIds: const ['target-1', 'target-2'],
        ttl: 3,
        payload: const {'text': 'Hello'},
      );

      expect(message.isBroadcast, isFalse);
      expect(message.targetIds, const ['target-1', 'target-2']);
    });

    test('should serialize to/from JSON string', () {
      final original = MeshMessage.create(
        type: MeshMessageType.data,
        sourceId: 'source-123',
        sourceUsername: 'Alice',
        targetIds: const ['target-1'],
        ttl: 5,
        payload: const {'text': 'Test message'},
      );

      final jsonString = original.toJsonString();
      final restored = MeshMessage.fromJsonString(jsonString);

      expect(restored.id, original.id);
      expect(restored.type, original.type);
      expect(restored.sourceId, original.sourceId);
      expect(restored.targetIds, original.targetIds);
      expect(restored.ttl, original.ttl);
    });

    test('should decrement TTL for forwarding', () {
      final original = MeshMessage.create(
        type: MeshMessageType.data,
        sourceId: 'source-123',
        sourceUsername: 'Alice',
        ttl: 5,
      );

      final forwarded = original.forForwarding();

      expect(forwarded.id, original.id);
      expect(forwarded.ttl, 4);
      expect(forwarded.canForward, isTrue);
    });

    test('should not forward when TTL is 0', () {
      final message = MeshMessage.create(
        type: MeshMessageType.data,
        sourceId: 'source-123',
        sourceUsername: 'Alice',
        ttl: 1,
      );

      final forwarded = message.forForwarding();

      expect(forwarded.ttl, 0);
      expect(forwarded.canForward, isFalse);
    });
  });

  group('MeshDataPayload', () {
    test('should create from JSON', () {
      final json = {
        'text': 'Hello, world!',
        'files': [
          {
            'id': 'file-123',
            'name': 'image.jpg',
            'size': 1024000,
            'mimeType': 'image/jpeg',
            'hostPeerId': 'peer-123',
            'totalChunks': 16,
          },
        ],
        'customData': {'key': 'value'},
      };

      final payload = MeshDataPayload.fromJson(json);

      expect(payload.text, 'Hello, world!');
      expect(payload.files.length, 1);
      expect(payload.files[0].name, 'image.jpg');
      expect(payload.customData['key'], 'value');
    });

    test('should serialize to JSON', () {
      const payload = MeshDataPayload(
        text: 'Test',
        files: [],
        customData: {'foo': 'bar'},
      );

      final json = payload.toJson();

      expect(json['text'], 'Test');
      expect(json['files'], isEmpty);
      expect((json['customData'] as Map<String, dynamic>)['foo'], 'bar');
    });
  });

  group('MeshFileInfo', () {
    test('should calculate total chunks', () {
      const fileInfo = MeshFileInfo(
        id: 'file-123',
        name: 'video.mp4',
        size: 1048576, // 1 MB
        hostPeerId: 'peer-123',
        chunkSize: 65536, // 64 KB
        totalChunks: 16,
      );

      expect(fileInfo.totalChunks, 16);
    });

    test('should serialize to/from JSON', () {
      const original = MeshFileInfo(
        id: 'file-456',
        name: 'document.pdf',
        size: 524288,
        mimeType: 'application/pdf',
        sha256: 'abc123hash',
        hostPeerId: 'peer-789',
        totalChunks: 8,
      );

      final json = original.toJson();
      final restored = MeshFileInfo.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.size, original.size);
      expect(restored.mimeType, original.mimeType);
      expect(restored.sha256, original.sha256);
    });
  });

  group('MeshPeerAnnounce', () {
    test('should serialize to/from JSON', () {
      const peer = MeshPeer(
        id: 'peer-123',
        username: 'Alice',
        transportType: MeshTransportType.wifiAware,
        state: MeshPeerState.connected,
        lastSeenAt: 1702742400000,
      );

      const knownPeer = MeshPeer(
        id: 'peer-456',
        username: 'Bob',
        transportType: MeshTransportType.wifiDirect,
        state: MeshPeerState.connected,
        lastSeenAt: 1702742400000,
        hopCount: 1,
      );

      const announce = MeshPeerAnnounce(peer: peer, knownPeers: [knownPeer]);

      final json = announce.toJson();
      final restored = MeshPeerAnnounce.fromJson(json);

      expect(restored.peer.id, 'peer-123');
      expect(restored.knownPeers.length, 1);
      expect(restored.knownPeers[0].id, 'peer-456');
    });
  });

  group('MeshMessageType', () {
    test('should convert to/from JSON value', () {
      expect(MeshMessageType.data.toJsonValue(), 'data');
      expect(MeshMessageType.peerAnnounce.toJsonValue(), 'peerAnnounce');

      expect(
        MeshMessageTypeExtension.fromJsonValue('data'),
        MeshMessageType.data,
      );
      expect(
        MeshMessageTypeExtension.fromJsonValue('invalid'),
        MeshMessageType.unknown,
      );
      expect(
        MeshMessageTypeExtension.fromJsonValue(null),
        MeshMessageType.unknown,
      );
    });
  });

  group('MeshFileTransferProgress', () {
    test('should calculate progress correctly', () {
      const progress = MeshFileTransferProgress(
        fileId: 'file-123',
        fileName: 'test.mp4',
        totalSize: 1048576,
        transferredBytes: 524288,
        chunksReceived: 8,
        totalChunks: 16,
        state: MeshFileTransferState.transferring,
      );

      expect(progress.progress, 0.5);
      expect(progress.progressPercent, 50);
    });

    test('should handle zero chunks', () {
      const progress = MeshFileTransferProgress(
        fileId: 'file-123',
        fileName: 'test.mp4',
        totalSize: 0,
        transferredBytes: 0,
        chunksReceived: 0,
        totalChunks: 0,
        state: MeshFileTransferState.pending,
      );

      expect(progress.progress, 0.0);
      expect(progress.progressPercent, 0);
    });
  });
}
