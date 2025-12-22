import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'adapters/mesh_transport_adapter.dart';
import 'adapters/wifi_aware_adapter.dart';
import 'adapters/wifi_direct_ble_adapter.dart';
import 'mesh_constants.dart';
import 'mesh_enums.dart';
import 'mesh_exceptions.dart';
import 'mesh_models.dart';
import 'mesh_router.dart';

/// Configuration options for [FlutterP2pMeshNode].
class MeshNodeConfig {
  /// Display name for this node.
  final String username;

  /// Custom peer ID (auto-generated if null).
  final String? peerId;

  /// Service name for discovery/advertising.
  final String serviceName;

  /// Default TTL for outgoing messages.
  final int defaultTtl;

  /// Whether to automatically connect to discovered peers.
  final bool autoConnect;

  /// Whether to automatically start advertising when starting.
  final bool autoAdvertise;

  /// Interval for broadcasting peer announcements.
  final Duration announceInterval;

  /// Creates a [MeshNodeConfig] instance.
  const MeshNodeConfig({
    required this.username,
    this.peerId,
    this.serviceName = 'flutter_p2p_mesh',
    this.defaultTtl = defaultMeshTtl,
    this.autoConnect = true,
    this.autoAdvertise = true,
    this.announceInterval = peerAnnounceInterval,
  });
}

/// High-level mesh networking node that combines discovery, routing, and transport.
///
/// [FlutterP2pMeshNode] acts as both a host and client, allowing peer-to-peer
/// communication in a mesh topology. Every node can discover, connect to,
/// and relay messages for other nodes.
///
/// **Key Features:**
/// - Automatic peer discovery and connection.
/// - Multi-hop message routing with TTL and deduplication.
/// - Peer health monitoring and stale peer detection.
/// - File transfer support (images, videos, etc.).
/// - Support for multiple transport adapters (Wi-Fi Aware, Wi-Fi Direct, etc.).
///
/// **Usage:**
/// ```dart
/// final meshNode = FlutterP2pMeshNode(
///   config: MeshNodeConfig(username: 'Alice'),
/// );
///
/// await meshNode.start();
///
/// // Listen for incoming messages
/// meshNode.onMessage.listen((message) {
///   print('Received from ${message.sourceUsername}: ${message.payload}');
/// });
///
/// // Send a broadcast message
/// await meshNode.broadcast(text: 'Hello, mesh!');
///
/// // Send to specific peer
/// await meshNode.sendTo(peerId: 'peer-123', text: 'Hello, Bob!');
///
/// // Clean up
/// await meshNode.stop();
/// ```
class FlutterP2pMeshNode {
  /// Configuration for this mesh node.
  final MeshNodeConfig config;

  static const String _logPrefix = 'MeshNode';

  /// Unique identifier for this node.
  late final String peerId;

  MeshRouter? _router;
  final List<MeshTransportAdapter> _adapters = [];
  final Map<String, StreamSubscription<dynamic>> _adapterSubscriptions = {};

  Timer? _announceTimer;
  bool _isStarted = false;

  final StreamController<MeshMessage> _messageController =
      StreamController<MeshMessage>.broadcast();
  final StreamController<MeshPeer> _peerController =
      StreamController<MeshPeer>.broadcast();
  final StreamController<MeshFileTransferProgress> _fileProgressController =
      StreamController<MeshFileTransferProgress>.broadcast();

  /// Stream of incoming data messages for this node.
  Stream<MeshMessage> get onMessage => _messageController.stream;

  /// Stream of peer updates (new peers, state changes).
  Stream<MeshPeer> get onPeerUpdate => _peerController.stream;

  /// Stream of file transfer progress updates.
  Stream<MeshFileTransferProgress> get onFileProgress =>
      _fileProgressController.stream;

  /// Whether the mesh node is currently active.
  bool get isStarted => _isStarted;

  /// List of all known peers in the mesh.
  List<MeshPeer> get peers => _router?.allPeers ?? [];

  /// List of directly connected peers.
  List<MeshPeer> get directPeers => _router?.directPeers ?? [];

  /// Number of peers in the mesh.
  int get peerCount => _router?.peerCount ?? 0;

  /// The local peer representation.
  MeshPeer get localPeer => MeshPeer(
        id: peerId,
        username: config.username,
        transportType: MeshTransportType.unknown,
        state: MeshPeerState.connected,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
        hopCount: 0,
      );

  /// Creates a [FlutterP2pMeshNode] instance.
  ///
  /// - [config]: Configuration options for the node.
  FlutterP2pMeshNode({required this.config}) {
    peerId = config.peerId ?? const Uuid().v4();
  }

  /// Starts the mesh node.
  ///
  /// This initializes transport adapters, starts discovery and advertising,
  /// and begins routing operations.
  ///
  /// Throws [MeshTransportException] if no transport adapters are available.
  Future<void> start() async {
    if (_isStarted) {
      debugPrint('$_logPrefix [${config.username}]: Already started.');
      return;
    }

    debugPrint('$_logPrefix [${config.username}]: Starting...');

    // Initialize router
    _router = MeshRouter(
      localPeerId: peerId,
      localUsername: config.username,
      onSendMessage: _sendViaTransport,
    );
    _router!.start();

    // Subscribe to router events
    _router!.incomingMessages.listen(_handleIncomingMessage);
    _router!.peerUpdates.listen((peer) {
      if (!_peerController.isClosed) {
        _peerController.add(peer);
      }
    });

    // Initialize transport adapters
    await _initializeAdapters();

    if (_adapters.isEmpty) {
      throw const MeshTransportException(
        'No transport adapters available on this device.',
      );
    }

    // Start discovery and advertising on all adapters
    for (final adapter in _adapters) {
      try {
        await adapter.startDiscovery(serviceName: config.serviceName);

        if (config.autoAdvertise) {
          await adapter.startAdvertising(
            localPeer: localPeer,
            serviceName: config.serviceName,
          );
        }
      } catch (e) {
        debugPrint(
          '$_logPrefix [${config.username}]: Error starting adapter ${adapter.transportType}: $e',
        );
      }
    }

    // Start periodic announcements
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(config.announceInterval, (_) {
      _broadcastPeerAnnounce();
    });

    _isStarted = true;
    debugPrint(
      '$_logPrefix [${config.username}]: Started with ${_adapters.length} adapter(s).',
    );
  }

  /// Stops the mesh node and releases all resources.
  Future<void> stop() async {
    if (!_isStarted) return;

    debugPrint('$_logPrefix [${config.username}]: Stopping...');

    _announceTimer?.cancel();
    _announceTimer = null;

    // Cancel adapter subscriptions
    for (final sub in _adapterSubscriptions.values) {
      await sub.cancel();
    }
    _adapterSubscriptions.clear();

    // Dispose adapters
    for (final adapter in _adapters) {
      try {
        await adapter.dispose();
      } catch (e) {
        debugPrint(
          '$_logPrefix [${config.username}]: Error disposing adapter: $e',
        );
      }
    }
    _adapters.clear();

    // Stop router
    await _router?.stop();
    _router = null;

    _isStarted = false;
    debugPrint('$_logPrefix [${config.username}]: Stopped.');
  }

  /// Disposes the mesh node.
  Future<void> dispose() async {
    await stop();
    await _messageController.close();
    await _peerController.close();
    await _fileProgressController.close();
  }

  /// Broadcasts a message to all peers in the mesh.
  ///
  /// - [text]: Text content of the message.
  /// - [files]: List of files to include (optional).
  /// - [customData]: Custom application data (optional).
  /// - [ttl]: Time-to-live for the message (defaults to config value).
  Future<void> broadcast({
    String text = '',
    List<MeshFileInfo> files = const [],
    Map<String, dynamic> customData = const {},
    int? ttl,
  }) async {
    _ensureStarted();

    final payload = MeshDataPayload(
      text: text,
      files: files,
      customData: customData,
    );

    final message = MeshMessage.create(
      type: MeshMessageType.data,
      sourceId: peerId,
      sourceUsername: config.username,
      targetIds: const [], // Empty = broadcast
      ttl: ttl ?? config.defaultTtl,
      payload: payload.toJson(),
    );

    await _router!.sendMessage(message);
    debugPrint(
      '$_logPrefix [${config.username}]: Broadcast message ${message.id}',
    );
  }

  /// Sends a message to specific peer(s).
  ///
  /// - [peerIds]: List of target peer IDs.
  /// - [text]: Text content of the message.
  /// - [files]: List of files to include (optional).
  /// - [customData]: Custom application data (optional).
  /// - [ttl]: Time-to-live for the message (defaults to config value).
  ///
  /// Throws [MeshRoutingException] if no route is available.
  Future<void> sendTo({
    required List<String> peerIds,
    String text = '',
    List<MeshFileInfo> files = const [],
    Map<String, dynamic> customData = const {},
    int? ttl,
  }) async {
    _ensureStarted();

    if (peerIds.isEmpty) {
      throw const MeshRoutingException('No target peer IDs specified.');
    }

    final payload = MeshDataPayload(
      text: text,
      files: files,
      customData: customData,
    );

    final message = MeshMessage.create(
      type: MeshMessageType.data,
      sourceId: peerId,
      sourceUsername: config.username,
      targetIds: peerIds,
      ttl: ttl ?? config.defaultTtl,
      payload: payload.toJson(),
    );

    await _router!.sendMessage(message);
    debugPrint(
      '$_logPrefix [${config.username}]: Sent message ${message.id} to ${peerIds.length} peer(s)',
    );
  }

  /// Sends a message to a single peer (convenience method).
  Future<void> sendToPeer({
    required String peerId,
    String text = '',
    List<MeshFileInfo> files = const [],
    Map<String, dynamic> customData = const {},
    int? ttl,
  }) async {
    await sendTo(
      peerIds: [peerId],
      text: text,
      files: files,
      customData: customData,
      ttl: ttl,
    );
  }

  /// Gets a peer by ID.
  MeshPeer? getPeer(String peerId) => _router?.getPeer(peerId);

  /// Manually connects to a discovered peer.
  Future<void> connectToPeer(String peerId) async {
    _ensureStarted();

    for (final adapter in _adapters) {
      try {
        final connectedPeer = await adapter.connect(peerId);
        _router!.addDirectPeer(connectedPeer);
        debugPrint(
          '$_logPrefix [${config.username}]: Connected to peer $peerId',
        );
        return;
      } catch (e) {
        debugPrint(
          '$_logPrefix [${config.username}]: Failed to connect via ${adapter.transportType}: $e',
        );
      }
    }

    throw MeshPeerNotFoundException(peerId, 'Could not connect to peer.');
  }

  /// Disconnects from a peer.
  Future<void> disconnectPeer(String peerId) async {
    _ensureStarted();

    for (final adapter in _adapters) {
      try {
        await adapter.disconnect(peerId);
      } catch (e) {
        debugPrint('$_logPrefix [${config.username}]: Error disconnecting: $e');
      }
    }

    _router!.removeDirectPeer(peerId);
  }

  /// Initializes available transport adapters.
  Future<void> _initializeAdapters() async {
    // Wi-Fi Aware (Android only)
    if (Platform.isAndroid) {
      try {
        final wifiAware = WifiAwareAdapter();
        if (await wifiAware.isAvailable) {
          await wifiAware.initialize();
          _adapters.add(wifiAware);
          _subscribeToAdapter(wifiAware);
          debugPrint(
            '$_logPrefix [${config.username}]: Wi-Fi Aware adapter initialized.',
          );
        }
      } catch (e) {
        debugPrint(
          '$_logPrefix [${config.username}]: Wi-Fi Aware not available: $e',
        );
      }
    }

    // Wi-Fi Direct + BLE credentials fallback
    try {
      final wifiDirectBle = WifiDirectBleAdapter(username: config.username);
      if (await wifiDirectBle.isAvailable) {
        await wifiDirectBle.initialize();
        _adapters.add(wifiDirectBle);
        _subscribeToAdapter(wifiDirectBle);
        debugPrint(
          '$_logPrefix [${config.username}]: Wi-Fi Direct + BLE adapter initialized.',
        );
      }
    } catch (e) {
      debugPrint(
        '$_logPrefix [${config.username}]: Wi-Fi Direct adapter unavailable: $e',
      );
    }
  }

  /// Subscribes to events from a transport adapter.
  void _subscribeToAdapter(MeshTransportAdapter adapter) {
    final key = adapter.transportType.name;

    // Discovered peers
    _adapterSubscriptions['${key}_discovered'] =
        adapter.discoveredPeers.listen((peer) {
      debugPrint(
        '$_logPrefix [${config.username}]: Discovered peer ${peer.username}',
      );

      if (!_peerController.isClosed) {
        _peerController.add(peer);
      }

      // Auto-connect if enabled
      if (config.autoConnect) {
        _autoConnectToPeer(peer, adapter);
      }
    });

    // Peer state changes
    _adapterSubscriptions['${key}_state'] =
        adapter.peerStateChanges.listen((peer) {
      if (peer.state == MeshPeerState.connected) {
        _router?.addDirectPeer(peer);
      } else if (peer.state == MeshPeerState.disconnected) {
        _router?.removeDirectPeer(peer.id);
      }

      if (!_peerController.isClosed) {
        _peerController.add(peer);
      }
    });

    // Incoming messages
    _adapterSubscriptions['${key}_messages'] =
        adapter.incomingMessages.listen((data) {
      _handleRawMessage(data.peerId, data.data);
    });
  }

  /// Auto-connects to a discovered peer.
  Future<void> _autoConnectToPeer(
    MeshPeer peer,
    MeshTransportAdapter adapter,
  ) async {
    // Don't connect to self
    if (peer.id == peerId) return;

    // Don't reconnect if already connected
    if (_router?.isDirectPeer(peer.id) ?? false) return;

    try {
      final connectedPeer = await adapter.connect(peer.id);
      _router?.addDirectPeer(connectedPeer);
      debugPrint(
        '$_logPrefix [${config.username}]: Auto-connected to ${peer.username}',
      );
    } catch (e) {
      debugPrint(
        '$_logPrefix [${config.username}]: Auto-connect failed for ${peer.username}: $e',
      );
    }
  }

  /// Handles raw message data received from transport.
  void _handleRawMessage(String fromPeerId, String rawData) {
    try {
      final message = MeshMessage.fromJsonString(rawData);
      _router?.processIncomingMessage(message, fromPeerId);
    } catch (e) {
      debugPrint('$_logPrefix [${config.username}]: Error parsing message: $e');
    }
  }

  /// Handles incoming messages from the router.
  void _handleIncomingMessage(MeshMessage message) {
    switch (message.type) {
      case MeshMessageType.data:
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
        break;

      case MeshMessageType.peerAnnounce:
        _handlePeerAnnounce(message);
        break;

      case MeshMessageType.ping:
        _handlePing(message);
        break;

      default:
        debugPrint(
          '$_logPrefix [${config.username}]: Unhandled message type: ${message.type}',
        );
    }
  }

  /// Handles peer announcement messages.
  void _handlePeerAnnounce(MeshMessage message) {
    try {
      final announce =
          MeshPeerAnnounce.fromJson(message.payload as Map<String, dynamic>);

      // Find who we received this from (direct peer)
      final fromPeerId = _router?.directPeers
          .firstWhere(
            (p) => p.id == message.sourceId,
            orElse: () => _router!.directPeers.first,
          )
          .id;

      if (fromPeerId != null) {
        _router?.handlePeerAnnounce(announce, fromPeerId);
      }
    } catch (e) {
      debugPrint(
        '$_logPrefix [${config.username}]: Error handling peer announce: $e',
      );
    }
  }

  /// Handles ping messages.
  void _handlePing(MeshMessage message) {
    // Send pong back
    final pong = MeshMessage.create(
      type: MeshMessageType.pong,
      sourceId: peerId,
      sourceUsername: config.username,
      targetIds: [message.sourceId],
      ttl: config.defaultTtl,
      payload: {'pingId': message.id},
    );

    _router?.sendMessage(pong);
  }

  /// Broadcasts a peer announcement.
  Future<void> _broadcastPeerAnnounce() async {
    if (!_isStarted || _router == null) return;

    final announce = _router!.createPeerAnnounce();
    await _router!.sendMessage(announce);
  }

  /// Sends a message via the appropriate transport adapter.
  Future<void> _sendViaTransport(String peerId, MeshMessage message) async {
    final jsonData = message.toJsonString();

    for (final adapter in _adapters) {
      if (adapter.connectedPeersList.any((p) => p.id == peerId)) {
        await adapter.send(peerId, jsonData);
        return;
      }
    }

    throw MeshTransportException('No connected transport for peer $peerId');
  }

  void _ensureStarted() {
    if (!_isStarted) {
      throw const MeshNotInitializedException(
        'MeshNode is not started. Call start() first.',
      );
    }
  }
}
