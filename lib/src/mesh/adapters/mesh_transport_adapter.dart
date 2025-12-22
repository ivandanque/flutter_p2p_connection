import 'dart:async';

import '../mesh_enums.dart';
import '../mesh_models.dart';

/// Abstract interface for mesh transport adapters.
///
/// Transport adapters handle the low-level discovery and communication
/// for different transport types (Wi-Fi Aware, Wi-Fi Direct, BLE, etc.).
///
/// Each adapter is responsible for:
/// - Discovering nearby peers.
/// - Establishing connections.
/// - Sending and receiving raw messages.
/// - Reporting connection state changes.
abstract class MeshTransportAdapter {
  /// The transport type provided by this adapter.
  MeshTransportType get transportType;

  /// Whether this transport is currently available on this device.
  Future<bool> get isAvailable;

  /// Whether the adapter is currently active (discovering/connected).
  bool get isActive;

  /// Stream of discovered peers.
  Stream<MeshPeer> get discoveredPeers;

  /// Stream of peer connection state changes.
  Stream<MeshPeer> get peerStateChanges;

  /// Stream of incoming messages from peers.
  Stream<({String peerId, String data})> get incomingMessages;

  /// List of currently connected peers for this adapter.
  List<MeshPeer> get connectedPeersList;

  /// Initializes the adapter.
  ///
  /// Call this before using any other methods.
  /// Throws [MeshTransportException] on failure.
  Future<void> initialize();

  /// Starts peer discovery.
  ///
  /// - [serviceName]: Optional service name to filter discovery.
  ///
  /// Discovered peers will be emitted on [discoveredPeers] stream.
  Future<void> startDiscovery({String? serviceName});

  /// Stops peer discovery.
  Future<void> stopDiscovery();

  /// Starts advertising this device for discovery by others.
  ///
  /// - [localPeer]: Information about this peer to advertise.
  /// - [serviceName]: Optional service name for advertising.
  Future<void> startAdvertising({
    required MeshPeer localPeer,
    String? serviceName,
  });

  /// Stops advertising.
  Future<void> stopAdvertising();

  /// Connects to a discovered peer.
  ///
  /// - [peerId]: The ID of the peer to connect to.
  ///
  /// Returns the connected [MeshPeer] with updated connection info.
  /// Throws [MeshTransportException] on failure.
  Future<MeshPeer> connect(String peerId);

  /// Disconnects from a peer.
  ///
  /// - [peerId]: The ID of the peer to disconnect from.
  Future<void> disconnect(String peerId);

  /// Sends a message to a connected peer.
  ///
  /// - [peerId]: The ID of the peer to send to.
  /// - [data]: The message data (typically JSON string).
  ///
  /// Throws [MeshTransportException] on failure.
  Future<void> send(String peerId, String data);

  /// Disposes the adapter and releases all resources.
  Future<void> dispose();
}

/// Mixin providing common adapter functionality.
mixin MeshTransportAdapterMixin {
  final Map<String, MeshPeer> discoveredPeersMap = {};
  final Map<String, MeshPeer> connectedPeersMap = {};

  /// Updates a discovered peer in the map.
  void updateDiscoveredPeer(MeshPeer peer) {
    discoveredPeersMap[peer.id] = peer;
  }

  /// Removes a discovered peer from the map.
  void removeDiscoveredPeer(String peerId) {
    discoveredPeersMap.remove(peerId);
  }

  /// Updates a connected peer in the map.
  void updateConnectedPeer(MeshPeer peer) {
    connectedPeersMap[peer.id] = peer;
  }

  /// Removes a connected peer from the map.
  void removeConnectedPeer(String peerId) {
    connectedPeersMap.remove(peerId);
  }

  /// Gets all discovered peers.
  List<MeshPeer> get discoveredPeersList => discoveredPeersMap.values.toList();

  /// Gets all connected peers.
  List<MeshPeer> get connectedPeersList => connectedPeersMap.values.toList();
}
