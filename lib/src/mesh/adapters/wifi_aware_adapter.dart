import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../mesh_enums.dart';
import '../mesh_exceptions.dart';
import '../mesh_models.dart';
import 'mesh_transport_adapter.dart';

/// Wi-Fi Aware (NAN) transport adapter for Android.
///
/// This adapter uses Android's Wi-Fi Aware APIs to discover peers
/// and establish high-throughput connections without a traditional
/// access point or internet connection.
///
/// **Requirements:**
/// - Android 8.0+ (API 26+)
/// - Device hardware support for Wi-Fi Aware
/// - Location permission (for discovery)
/// - `NEARBY_WIFI_DEVICES` permission (Android 12+)
///
/// **Limitations:**
/// - Not supported on iOS (Wi-Fi Aware is Android-only).
/// - Hardware support varies by device/OEM.
/// - Requires Wi-Fi to be enabled.
class WifiAwareAdapter extends MeshTransportAdapter
    with MeshTransportAdapterMixin {
  static const String _logPrefix = 'WifiAwareAdapter';
  static const String _channelName =
      'com.ugo.studio.plugins.flutter_p2p_connection/wifi_aware';

  final MethodChannel _channel = const MethodChannel(_channelName);

  final StreamController<MeshPeer> _discoveredPeersController =
      StreamController<MeshPeer>.broadcast();
  final StreamController<MeshPeer> _peerStateController =
      StreamController<MeshPeer>.broadcast();
  final StreamController<({String peerId, String data})> _incomingController =
      StreamController<({String peerId, String data})>.broadcast();

  bool _isInitialized = false;
  bool _isDiscovering = false;
  bool _isAdvertising = false;

  @override
  MeshTransportType get transportType => MeshTransportType.wifiAware;

  @override
  Future<bool> get isAvailable async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isWifiAwareAvailable');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('$_logPrefix: Error checking availability: $e');
      return false;
    }
  }

  @override
  bool get isActive => _isDiscovering || _isAdvertising;

  @override
  Stream<MeshPeer> get discoveredPeers => _discoveredPeersController.stream;

  @override
  Stream<MeshPeer> get peerStateChanges => _peerStateController.stream;

  @override
  Stream<({String peerId, String data})> get incomingMessages =>
      _incomingController.stream;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (!Platform.isAndroid) {
      throw const WifiAwareNotSupportedException(
        'Wi-Fi Aware is only supported on Android.',
      );
    }

    final available = await isAvailable;
    if (!available) {
      throw const WifiAwareNotSupportedException(
        'Wi-Fi Aware is not available on this device.',
      );
    }

    // Set up method call handler for callbacks from native
    _channel.setMethodCallHandler(_handleMethodCall);

    try {
      await _channel.invokeMethod<void>('initializeWifiAware');
      _isInitialized = true;
      debugPrint('$_logPrefix: Initialized successfully.');
    } on PlatformException catch (e) {
      throw MeshTransportException('Failed to initialize Wi-Fi Aware', e);
    }
  }

  @override
  Future<void> startDiscovery({String? serviceName}) async {
    _ensureInitialized();

    if (_isDiscovering) {
      debugPrint('$_logPrefix: Already discovering.');
      return;
    }

    try {
      await _channel.invokeMethod<void>('startDiscovery', {
        'serviceName': serviceName ?? 'flutter_p2p_mesh',
      });
      _isDiscovering = true;
      debugPrint('$_logPrefix: Discovery started.');
    } on PlatformException catch (e) {
      throw MeshTransportException('Failed to start discovery', e);
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;

    try {
      await _channel.invokeMethod<void>('stopDiscovery');
      _isDiscovering = false;
      debugPrint('$_logPrefix: Discovery stopped.');
    } on PlatformException catch (e) {
      debugPrint('$_logPrefix: Error stopping discovery: $e');
    }
  }

  @override
  Future<void> startAdvertising({
    required MeshPeer localPeer,
    String? serviceName,
  }) async {
    _ensureInitialized();

    if (_isAdvertising) {
      debugPrint('$_logPrefix: Already advertising.');
      return;
    }

    try {
      await _channel.invokeMethod<void>('startAdvertising', {
        'serviceName': serviceName ?? 'flutter_p2p_mesh',
        'peerId': localPeer.id,
        'username': localPeer.username,
        'metadata': localPeer.metadata,
      });
      _isAdvertising = true;
      debugPrint('$_logPrefix: Advertising started as ${localPeer.username}.');
    } on PlatformException catch (e) {
      throw MeshTransportException('Failed to start advertising', e);
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    try {
      await _channel.invokeMethod<void>('stopAdvertising');
      _isAdvertising = false;
      debugPrint('$_logPrefix: Advertising stopped.');
    } on PlatformException catch (e) {
      debugPrint('$_logPrefix: Error stopping advertising: $e');
    }
  }

  @override
  Future<MeshPeer> connect(String peerId) async {
    _ensureInitialized();

    final discoveredPeer = discoveredPeersMap[peerId];
    if (discoveredPeer == null) {
      throw MeshPeerNotFoundException(peerId, 'Peer not discovered.');
    }

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'connectToPeer',
        {'peerId': peerId},
      );

      if (result == null) {
        throw const MeshTransportException('Connection returned null result');
      }

      final connectedPeer = discoveredPeer.copyWith(
        state: MeshPeerState.connected,
        address: result['address'] as String?,
        port: result['port'] as int?,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      );

      updateConnectedPeer(connectedPeer);

      if (!_peerStateController.isClosed) {
        _peerStateController.add(connectedPeer);
      }

      debugPrint('$_logPrefix: Connected to peer $peerId.');
      return connectedPeer;
    } on PlatformException catch (e) {
      throw MeshTransportException('Failed to connect to peer $peerId', e);
    }
  }

  @override
  Future<void> disconnect(String peerId) async {
    try {
      await _channel.invokeMethod<void>('disconnectPeer', {'peerId': peerId});

      final peer = connectedPeersMap[peerId];
      if (peer != null) {
        final disconnectedPeer = peer.copyWith(
          state: MeshPeerState.disconnected,
        );
        removeConnectedPeer(peerId);

        if (!_peerStateController.isClosed) {
          _peerStateController.add(disconnectedPeer);
        }
      }

      debugPrint('$_logPrefix: Disconnected from peer $peerId.');
    } on PlatformException catch (e) {
      debugPrint('$_logPrefix: Error disconnecting from $peerId: $e');
    }
  }

  @override
  Future<void> send(String peerId, String data) async {
    _ensureInitialized();

    if (!connectedPeersMap.containsKey(peerId)) {
      throw MeshTransportException('Peer $peerId is not connected.');
    }

    try {
      await _channel.invokeMethod<void>('sendData', {
        'peerId': peerId,
        'data': data,
      });
    } on PlatformException catch (e) {
      throw MeshTransportException('Failed to send data to $peerId', e);
    }
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await stopAdvertising();

    // Disconnect all peers
    for (final peerId in connectedPeersMap.keys.toList()) {
      await disconnect(peerId);
    }

    try {
      await _channel.invokeMethod<void>('disposeWifiAware');
    } catch (e) {
      debugPrint('$_logPrefix: Error disposing: $e');
    }

    await _discoveredPeersController.close();
    await _peerStateController.close();
    await _incomingController.close();

    _isInitialized = false;
    debugPrint('$_logPrefix: Disposed.');
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw const MeshNotInitializedException(
        'WifiAwareAdapter is not initialized. Call initialize() first.',
      );
    }
  }

  /// Handles method calls from native platform.
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPeerDiscovered':
        _handlePeerDiscovered(call.arguments as Map<dynamic, dynamic>);
        break;
      case 'onPeerLost':
        _handlePeerLost(call.arguments as String);
        break;
      case 'onConnectionStateChanged':
        _handleConnectionStateChanged(call.arguments as Map<dynamic, dynamic>);
        break;
      case 'onDataReceived':
        _handleDataReceived(call.arguments as Map<dynamic, dynamic>);
        break;
      case 'onError':
        _handleError(call.arguments as Map<dynamic, dynamic>);
        break;
      default:
        debugPrint('$_logPrefix: Unknown method call: ${call.method}');
    }
  }

  void _handlePeerDiscovered(Map<dynamic, dynamic> data) {
    final peer = MeshPeer(
      id: data['peerId'] as String,
      username: data['username'] as String? ?? 'Unknown',
      transportType: MeshTransportType.wifiAware,
      state: MeshPeerState.discovered,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      metadata: Map<String, dynamic>.from(data['metadata'] as Map? ?? {}),
    );

    updateDiscoveredPeer(peer);

    if (!_discoveredPeersController.isClosed) {
      _discoveredPeersController.add(peer);
    }

    debugPrint('$_logPrefix: Discovered peer ${peer.username} (${peer.id})');
  }

  void _handlePeerLost(String peerId) {
    final peer = discoveredPeersMap[peerId];
    removeDiscoveredPeer(peerId);

    if (peer != null && !_peerStateController.isClosed) {
      _peerStateController.add(
        peer.copyWith(state: MeshPeerState.disconnected),
      );
    }

    debugPrint('$_logPrefix: Lost peer $peerId');
  }

  void _handleConnectionStateChanged(Map<dynamic, dynamic> data) {
    final peerId = data['peerId'] as String;
    final stateStr = data['state'] as String?;

    final state = MeshPeerState.values.firstWhere(
      (e) => e.name == stateStr,
      orElse: () => MeshPeerState.disconnected,
    );

    final existingPeer =
        connectedPeersMap[peerId] ?? discoveredPeersMap[peerId];
    if (existingPeer != null) {
      final updatedPeer = existingPeer.copyWith(
        state: state,
        address: data['address'] as String?,
        port: data['port'] as int?,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      );

      if (state == MeshPeerState.connected) {
        updateConnectedPeer(updatedPeer);
      } else if (state == MeshPeerState.disconnected) {
        removeConnectedPeer(peerId);
      }

      if (!_peerStateController.isClosed) {
        _peerStateController.add(updatedPeer);
      }
    }

    debugPrint('$_logPrefix: Peer $peerId state changed to ${state.name}');
  }

  void _handleDataReceived(Map<dynamic, dynamic> data) {
    final peerId = data['peerId'] as String;
    final payload = data['data'] as String;

    // Update last-seen time
    final peer = connectedPeersMap[peerId];
    if (peer != null) {
      updateConnectedPeer(
        peer.copyWith(lastSeenAt: DateTime.now().millisecondsSinceEpoch),
      );
    }

    if (!_incomingController.isClosed) {
      _incomingController.add((peerId: peerId, data: payload));
    }
  }

  void _handleError(Map<dynamic, dynamic> data) {
    final errorCode = data['code'] as String?;
    final errorMessage = data['message'] as String?;
    debugPrint('$_logPrefix: Error ($errorCode): $errorMessage');
  }
}
