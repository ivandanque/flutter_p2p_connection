import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'mesh_constants.dart';
import 'mesh_enums.dart';
import 'mesh_exceptions.dart';
import 'mesh_models.dart';

/// Callback type for message sending via transport.
typedef SendMessageCallback =
    Future<void> Function(String peerId, MeshMessage message);

/// Manages routing, forwarding, and deduplication for the mesh network.
///
/// The [MeshRouter] handles:
/// - Routing table management (peers and next-hop information).
/// - Message deduplication using message IDs.
/// - TTL decrement and drop logic.
/// - Message forwarding to next-hop peers.
/// - Peer health tracking and stale peer detection.
class MeshRouter {
  /// The local node's peer ID.
  final String localPeerId;

  /// The local node's username.
  final String localUsername;

  /// Callback to send a message to a specific peer via transport.
  final SendMessageCallback onSendMessage;

  static const String _logPrefix = 'MeshRouter';

  /// Routing table: peer ID -> MeshPeer info.
  final Map<String, MeshPeer> _peers = {};

  /// Direct connections: peer ID -> MeshPeer (hopCount == 0).
  final Map<String, MeshPeer> _directPeers = {};

  /// Message deduplication cache: message ID -> timestamp.
  final LinkedHashMap<String, int> _seenMessages = LinkedHashMap();

  /// Stream controller for incoming messages destined for this node.
  final StreamController<MeshMessage> _incomingMessageController =
      StreamController<MeshMessage>.broadcast();

  /// Stream controller for peer updates.
  final StreamController<MeshPeer> _peerUpdateController =
      StreamController<MeshPeer>.broadcast();

  /// Stream controller for peer removals.
  final StreamController<String> _peerRemovedController =
      StreamController<String>.broadcast();

  Timer? _healthCheckTimer;
  Timer? _deduplicationCleanupTimer;

  /// Stream of incoming messages for this node.
  Stream<MeshMessage> get incomingMessages => _incomingMessageController.stream;

  /// Stream of peer updates (new peers or state changes).
  Stream<MeshPeer> get peerUpdates => _peerUpdateController.stream;

  /// Stream of removed peer IDs.
  Stream<String> get peerRemovals => _peerRemovedController.stream;

  /// List of all known peers in the routing table.
  List<MeshPeer> get allPeers => _peers.values.toList();

  /// List of directly connected peers.
  List<MeshPeer> get directPeers => _directPeers.values.toList();

  /// Number of peers in the routing table.
  int get peerCount => _peers.length;

  /// Creates a [MeshRouter] instance.
  ///
  /// - [localPeerId]: Unique identifier for this node.
  /// - [localUsername]: Display name for this node.
  /// - [onSendMessage]: Callback invoked to send messages via transport.
  MeshRouter({
    required this.localPeerId,
    required this.localUsername,
    required this.onSendMessage,
  });

  /// Starts the router (health checks, cleanup timers).
  void start() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(peerHealthCheckInterval, (_) {
      _checkPeerHealth();
    });

    _deduplicationCleanupTimer?.cancel();
    _deduplicationCleanupTimer = Timer.periodic(messageDeduplicationWindow, (
      _,
    ) {
      _cleanupDeduplicationCache();
    });

    debugPrint('$_logPrefix [$localUsername]: Started.');
  }

  /// Stops the router and releases resources.
  Future<void> stop() async {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _deduplicationCleanupTimer?.cancel();
    _deduplicationCleanupTimer = null;

    await _incomingMessageController.close();
    await _peerUpdateController.close();
    await _peerRemovedController.close();

    _peers.clear();
    _directPeers.clear();
    _seenMessages.clear();

    debugPrint('$_logPrefix [$localUsername]: Stopped.');
  }

  /// Adds or updates a direct peer in the routing table.
  ///
  /// Call this when a new direct connection is established.
  void addDirectPeer(MeshPeer peer) {
    final directPeer = peer.copyWith(
      hopCount: 0,
      nextHopPeerId: null,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      state: MeshPeerState.connected,
    );

    _directPeers[peer.id] = directPeer;
    _peers[peer.id] = directPeer;

    if (!_peerUpdateController.isClosed) {
      _peerUpdateController.add(directPeer);
    }

    debugPrint(
      '$_logPrefix [$localUsername]: Added direct peer: ${peer.username} (${peer.id})',
    );
  }

  /// Removes a direct peer from the routing table.
  ///
  /// Call this when a direct connection is lost.
  void removeDirectPeer(String peerId) {
    _directPeers.remove(peerId);

    // Also remove any peers that were reachable only through this peer
    final peersToRemove = <String>[];
    for (final entry in _peers.entries) {
      if (entry.value.nextHopPeerId == peerId || entry.key == peerId) {
        peersToRemove.add(entry.key);
      }
    }

    for (final id in peersToRemove) {
      _peers.remove(id);
      if (!_peerRemovedController.isClosed) {
        _peerRemovedController.add(id);
      }
    }

    debugPrint(
      '$_logPrefix [$localUsername]: Removed direct peer: $peerId (and ${peersToRemove.length - 1} dependent peers)',
    );
  }

  /// Updates routing information based on a peer announcement.
  ///
  /// This is called when receiving a [MeshMessageType.peerAnnounce] message.
  void handlePeerAnnounce(
    MeshPeerAnnounce announce,
    String receivedFromPeerId,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Update the announcing peer's last-seen time
    if (_peers.containsKey(announce.peer.id)) {
      final updated = _peers[announce.peer.id]!.copyWith(lastSeenAt: now);
      _peers[announce.peer.id] = updated;
      if (_directPeers.containsKey(announce.peer.id)) {
        _directPeers[announce.peer.id] = updated;
      }
    }

    // Learn about peers known to the announcing peer
    for (final knownPeer in announce.knownPeers) {
      if (knownPeer.id == localPeerId) continue; // Skip self

      final existingPeer = _peers[knownPeer.id];
      final newHopCount = knownPeer.hopCount + 1;

      // Add or update if we don't know this peer, or if this is a shorter path
      if (existingPeer == null || newHopCount < existingPeer.hopCount) {
        final updatedPeer = knownPeer.copyWith(
          hopCount: newHopCount,
          nextHopPeerId: receivedFromPeerId,
          lastSeenAt: now,
          state: MeshPeerState.connected,
        );
        _peers[knownPeer.id] = updatedPeer;

        if (!_peerUpdateController.isClosed) {
          _peerUpdateController.add(updatedPeer);
        }

        debugPrint(
          '$_logPrefix [$localUsername]: Learned about peer ${knownPeer.username} via ${announce.peer.username} (hops: $newHopCount)',
        );
      }
    }
  }

  /// Processes an incoming message and routes it appropriately.
  ///
  /// Returns `true` if the message was processed (delivered or forwarded).
  /// Returns `false` if the message was dropped (duplicate or TTL expired).
  Future<bool> processIncomingMessage(
    MeshMessage message,
    String receivedFromPeerId,
  ) async {
    // 1. Check for duplicates
    if (_isDuplicate(message.id)) {
      debugPrint(
        '$_logPrefix [$localUsername]: Dropping duplicate message ${message.id}',
      );
      return false;
    }

    // Mark as seen
    _markAsSeen(message.id);

    // Update sender's last-seen time
    if (_peers.containsKey(message.sourceId)) {
      final updated = _peers[message.sourceId]!.copyWith(
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      );
      _peers[message.sourceId] = updated;
    }

    // 2. Check if we are a target (or it's a broadcast)
    final isForUs =
        message.isBroadcast || message.targetIds.contains(localPeerId);

    if (isForUs) {
      // Deliver to local node
      if (!_incomingMessageController.isClosed) {
        _incomingMessageController.add(message);
      }
      debugPrint(
        '$_logPrefix [$localUsername]: Delivered message ${message.id} from ${message.sourceUsername}',
      );
    }

    // 3. Forward if needed (broadcast or targeted to others, and TTL allows)
    final shouldForward =
        message.canForward &&
        (message.isBroadcast ||
            message.targetIds.any((id) => id != localPeerId));

    if (shouldForward) {
      await _forwardMessage(message, receivedFromPeerId);
    }

    return true;
  }

  /// Sends a message originated from this node.
  ///
  /// - [message]: The message to send.
  ///
  /// Throws [MeshRoutingException] if no route is available for targeted messages.
  Future<void> sendMessage(MeshMessage message) async {
    // Mark as seen to prevent echo
    _markAsSeen(message.id);

    if (message.isBroadcast) {
      // Broadcast to all direct peers
      for (final peer in _directPeers.values) {
        try {
          await onSendMessage(peer.id, message);
        } catch (e) {
          debugPrint(
            '$_logPrefix [$localUsername]: Failed to send to ${peer.username}: $e',
          );
        }
      }
      debugPrint(
        '$_logPrefix [$localUsername]: Broadcast message ${message.id} to ${_directPeers.length} peers',
      );
    } else {
      // Send to specific targets
      final sentTo = <String>{};
      for (final targetId in message.targetIds) {
        final nextHop = _getNextHop(targetId);
        if (nextHop != null && !sentTo.contains(nextHop)) {
          sentTo.add(nextHop);
          try {
            await onSendMessage(nextHop, message);
          } catch (e) {
            debugPrint(
              '$_logPrefix [$localUsername]: Failed to route to $targetId via $nextHop: $e',
            );
          }
        } else if (nextHop == null) {
          debugPrint(
            '$_logPrefix [$localUsername]: No route to target $targetId',
          );
        }
      }

      if (sentTo.isEmpty && message.targetIds.isNotEmpty) {
        throw MeshRoutingException(
          'No route available for any target',
          message.id,
        );
      }
    }
  }

  /// Creates a peer announce message for broadcasting.
  MeshMessage createPeerAnnounce() {
    final selfPeer = MeshPeer(
      id: localPeerId,
      username: localUsername,
      transportType: MeshTransportType.unknown,
      state: MeshPeerState.connected,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      hopCount: 0,
    );

    final announce = MeshPeerAnnounce(
      peer: selfPeer,
      knownPeers: _peers.values.where((p) => p.id != localPeerId).toList(),
    );

    return MeshMessage.create(
      type: MeshMessageType.peerAnnounce,
      sourceId: localPeerId,
      sourceUsername: localUsername,
      ttl: defaultMeshTtl,
      payload: announce.toJson(),
    );
  }

  /// Gets a peer by ID, or null if not found.
  MeshPeer? getPeer(String peerId) => _peers[peerId];

  /// Checks if a peer is directly connected.
  bool isDirectPeer(String peerId) => _directPeers.containsKey(peerId);

  /// Gets the next-hop peer ID for reaching a target.
  String? _getNextHop(String targetId) {
    // Direct peer: send directly
    if (_directPeers.containsKey(targetId)) {
      return targetId;
    }

    // Indirect peer: use next-hop
    final peer = _peers[targetId];
    return peer?.nextHopPeerId;
  }

  /// Forwards a message to appropriate peers.
  Future<void> _forwardMessage(
    MeshMessage message,
    String receivedFromPeerId,
  ) async {
    final forwardedMessage = message.forForwarding();

    if (forwardedMessage.ttl <= 0) {
      debugPrint(
        '$_logPrefix [$localUsername]: TTL expired for message ${message.id}, not forwarding',
      );
      return;
    }

    if (forwardedMessage.isBroadcast) {
      // Forward to all direct peers except the one we received from
      for (final peer in _directPeers.values) {
        if (peer.id == receivedFromPeerId) continue;
        try {
          await onSendMessage(peer.id, forwardedMessage);
        } catch (e) {
          debugPrint(
            '$_logPrefix [$localUsername]: Failed to forward to ${peer.username}: $e',
          );
        }
      }
    } else {
      // Forward to next-hops for remaining targets (excluding us)
      final remainingTargets = forwardedMessage.targetIds
          .where((id) => id != localPeerId)
          .toList();
      final sentTo = <String>{};

      for (final targetId in remainingTargets) {
        final nextHop = _getNextHop(targetId);
        if (nextHop != null &&
            nextHop != receivedFromPeerId &&
            !sentTo.contains(nextHop)) {
          sentTo.add(nextHop);
          try {
            await onSendMessage(nextHop, forwardedMessage);
          } catch (e) {
            debugPrint(
              '$_logPrefix [$localUsername]: Failed to forward to $nextHop: $e',
            );
          }
        }
      }
    }

    debugPrint(
      '$_logPrefix [$localUsername]: Forwarded message ${message.id} (TTL: ${forwardedMessage.ttl})',
    );
  }

  /// Checks if a message ID has been seen before.
  bool _isDuplicate(String messageId) => _seenMessages.containsKey(messageId);

  /// Marks a message ID as seen.
  void _markAsSeen(String messageId) {
    _seenMessages[messageId] = DateTime.now().millisecondsSinceEpoch;

    // Enforce cache size limit
    while (_seenMessages.length > maxDeduplicationCacheSize) {
      _seenMessages.remove(_seenMessages.keys.first);
    }
  }

  /// Cleans up old entries from the deduplication cache.
  void _cleanupDeduplicationCache() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch -
        messageDeduplicationWindow.inMilliseconds;

    _seenMessages.removeWhere((_, timestamp) => timestamp < cutoff);
  }

  /// Checks peer health and marks stale peers.
  void _checkPeerHealth() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final staleThreshold = now - peerStaleTimeout.inMilliseconds;

    final stalePeers = <String>[];

    for (final entry in _peers.entries) {
      if (entry.value.lastSeenAt < staleThreshold &&
          entry.value.state != MeshPeerState.stale) {
        stalePeers.add(entry.key);
      }
    }

    for (final peerId in stalePeers) {
      final peer = _peers[peerId]!;
      final stalePeer = peer.copyWith(state: MeshPeerState.stale);
      _peers[peerId] = stalePeer;

      if (_directPeers.containsKey(peerId)) {
        _directPeers[peerId] = stalePeer;
      }

      if (!_peerUpdateController.isClosed) {
        _peerUpdateController.add(stalePeer);
      }

      debugPrint(
        '$_logPrefix [$localUsername]: Peer ${peer.username} is now stale',
      );
    }
  }
}
