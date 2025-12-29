import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_constants.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_enums.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_exceptions.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_models.dart';
import 'package:flutter_p2p_connection/src/mesh/mesh_router.dart';

void main() {
  group('MeshRouter', () {
    late MeshRouter router;
    late List<(String, MeshMessage)> sentMessages;

    setUp(() {
      sentMessages = [];
      router = MeshRouter(
        localPeerId: 'local-peer',
        localUsername: 'LocalUser',
        onSendMessage: (peerId, message) async {
          sentMessages.add((peerId, message));
        },
      );
      router.start();
    });

    tearDown(() async {
      await router.stop();
    });

    group('peer management', () {
      test('should add direct peer', () {
        const peer = MeshPeer(
          id: 'peer-1',
          username: 'Alice',
          transportType: MeshTransportType.wifiAware,
          state: MeshPeerState.discovered,
          lastSeenAt: 0,
        );

        router.addDirectPeer(peer);

        expect(router.peerCount, 1);
        expect(router.directPeers.length, 1);
        expect(router.isDirectPeer('peer-1'), isTrue);
      });

      test('should remove direct peer and dependent peers', () {
        // Add direct peer
        const directPeer = MeshPeer(
          id: 'peer-1',
          username: 'Alice',
          transportType: MeshTransportType.wifiAware,
          state: MeshPeerState.connected,
          lastSeenAt: 0,
        );
        router.addDirectPeer(directPeer);

        // Simulate learning about an indirect peer via peer-1
        const announce = MeshPeerAnnounce(
          peer: directPeer,
          knownPeers: [
            MeshPeer(
              id: 'peer-2',
              username: 'Bob',
              transportType: MeshTransportType.wifiAware,
              state: MeshPeerState.connected,
              lastSeenAt: 0,
              hopCount: 0,
            ),
          ],
        );
        router.handlePeerAnnounce(announce, 'peer-1');

        expect(router.peerCount, 2);

        // Remove direct peer
        router.removeDirectPeer('peer-1');

        // Both peers should be removed (peer-2 depended on peer-1)
        expect(router.peerCount, 0);
        expect(router.isDirectPeer('peer-1'), isFalse);
      });

      test('should update routing from peer announce', () {
        // First, add direct peer
        const directPeer = MeshPeer(
          id: 'peer-1',
          username: 'Alice',
          transportType: MeshTransportType.wifiAware,
          state: MeshPeerState.connected,
          lastSeenAt: 0,
        );
        router.addDirectPeer(directPeer);

        // Peer-1 tells us about peer-2 (1 hop from peer-1)
        const announce = MeshPeerAnnounce(
          peer: directPeer,
          knownPeers: [
            MeshPeer(
              id: 'peer-2',
              username: 'Bob',
              transportType: MeshTransportType.wifiDirect,
              state: MeshPeerState.connected,
              lastSeenAt: 0,
              hopCount: 0, // 0 hops from peer-1
            ),
          ],
        );

        router.handlePeerAnnounce(announce, 'peer-1');

        expect(router.peerCount, 2);

        final peer2 = router.getPeer('peer-2');
        expect(peer2, isNotNull);
        expect(peer2!.hopCount, 1); // 1 hop from us (via peer-1)
        expect(peer2.nextHopPeerId, 'peer-1');
      });
    });

    group('message routing', () {
      setUp(() {
        // Add two direct peers
        router.addDirectPeer(
          const MeshPeer(
            id: 'peer-1',
            username: 'Alice',
            transportType: MeshTransportType.wifiAware,
            state: MeshPeerState.connected,
            lastSeenAt: 0,
          ),
        );
        router.addDirectPeer(
          const MeshPeer(
            id: 'peer-2',
            username: 'Bob',
            transportType: MeshTransportType.wifiAware,
            state: MeshPeerState.connected,
            lastSeenAt: 0,
          ),
        );
      });

      test('should broadcast to all direct peers', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'local-peer',
          sourceUsername: 'LocalUser',
          ttl: defaultMeshTtl,
          payload: const {'text': 'Hello'},
        );

        await router.sendMessage(message);

        expect(sentMessages.length, 2);
        expect(sentMessages.map((e) => e.$1).toSet(), {'peer-1', 'peer-2'});
      });

      test('should send targeted message to specific peer', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'local-peer',
          sourceUsername: 'LocalUser',
          targetIds: const ['peer-1'],
          ttl: defaultMeshTtl,
          payload: const {'text': 'Hello Alice'},
        );

        await router.sendMessage(message);

        expect(sentMessages.length, 1);
        expect(sentMessages[0].$1, 'peer-1');
      });

      test('should throw when no route available', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'local-peer',
          sourceUsername: 'LocalUser',
          targetIds: const ['unknown-peer'],
          ttl: defaultMeshTtl,
        );

        expect(
          () => router.sendMessage(message),
          throwsA(isA<MeshRoutingException>()),
        );
      });
    });

    group('message deduplication', () {
      test('should deliver message once', () async {
        final receivedMessages = <MeshMessage>[];
        router.incomingMessages.listen(receivedMessages.add);

        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'peer-1',
          sourceUsername: 'Alice',
          ttl: defaultMeshTtl,
          payload: const {'text': 'Hello'},
        );

        // Process same message twice
        await router.processIncomingMessage(message, 'peer-1');
        await router.processIncomingMessage(message, 'peer-1');

        // Allow stream to emit
        await Future<void>.delayed(Duration.zero);

        expect(receivedMessages.length, 1);
      });

      test('should return false for duplicate message', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'peer-1',
          sourceUsername: 'Alice',
          ttl: defaultMeshTtl,
        );

        final firstResult = await router.processIncomingMessage(
          message,
          'peer-1',
        );
        final secondResult = await router.processIncomingMessage(
          message,
          'peer-1',
        );

        expect(firstResult, isTrue);
        expect(secondResult, isFalse);
      });
    });

    group('TTL handling', () {
      setUp(() {
        router.addDirectPeer(
          const MeshPeer(
            id: 'peer-1',
            username: 'Alice',
            transportType: MeshTransportType.wifiAware,
            state: MeshPeerState.connected,
            lastSeenAt: 0,
          ),
        );
        router.addDirectPeer(
          const MeshPeer(
            id: 'peer-2',
            username: 'Bob',
            transportType: MeshTransportType.wifiAware,
            state: MeshPeerState.connected,
            lastSeenAt: 0,
          ),
        );
      });

      test('should decrement TTL when forwarding', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'peer-1',
          sourceUsername: 'Alice',
          ttl: 3,
          payload: const {'text': 'Hello'},
        );

        await router.processIncomingMessage(message, 'peer-1');

        // Check forwarded message has decremented TTL
        expect(sentMessages.length, 1);
        expect(sentMessages[0].$2.ttl, 2);
      });

      test('should not forward when TTL is 1', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'peer-1',
          sourceUsername: 'Alice',
          ttl: 1,
          payload: const {'text': 'Hello'},
        );

        await router.processIncomingMessage(message, 'peer-1');

        // Should not forward (TTL would become 0)
        expect(sentMessages, isEmpty);
      });

      test('should not forward back to sender', () async {
        final message = MeshMessage.create(
          type: MeshMessageType.data,
          sourceId: 'peer-1',
          sourceUsername: 'Alice',
          ttl: 5,
          payload: const {'text': 'Hello'},
        );

        await router.processIncomingMessage(message, 'peer-1');

        // Should only forward to peer-2, not back to peer-1
        expect(sentMessages.length, 1);
        expect(sentMessages[0].$1, 'peer-2');
      });
    });

    group('peer announce', () {
      test('should create valid peer announce message', () {
        router.addDirectPeer(
          const MeshPeer(
            id: 'peer-1',
            username: 'Alice',
            transportType: MeshTransportType.wifiAware,
            state: MeshPeerState.connected,
            lastSeenAt: 0,
          ),
        );

        final announce = router.createPeerAnnounce();

        expect(announce.type, MeshMessageType.peerAnnounce);
        expect(announce.sourceId, 'local-peer');
        expect(announce.sourceUsername, 'LocalUser');
        expect(announce.isBroadcast, isTrue);

        final payload = MeshPeerAnnounce.fromJson(
          announce.payload as Map<String, dynamic>,
        );
        expect(payload.peer.id, 'local-peer');
        expect(payload.knownPeers.length, 1);
        expect(payload.knownPeers[0].id, 'peer-1');
      });
    });
  });

  group('MeshExceptions', () {
    test('MeshNotInitializedException should have proper message', () {
      const exception = MeshNotInitializedException('Test message');
      expect(exception.toString(), contains('Test message'));
    });

    test('MeshPeerNotFoundException should include peerId', () {
      const exception = MeshPeerNotFoundException('peer-123', 'Not found');
      expect(exception.toString(), contains('peer-123'));
      expect(exception.toString(), contains('Not found'));
    });

    test('MeshRoutingException should include messageId', () {
      const exception = MeshRoutingException('No route', 'msg-456');
      expect(exception.toString(), contains('No route'));
      expect(exception.toString(), contains('msg-456'));
    });
  });
}
