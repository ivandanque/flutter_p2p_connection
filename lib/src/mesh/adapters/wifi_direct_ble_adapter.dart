import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection_platform_interface.dart';

import '../../common/p2p_constants.dart';
import 'mesh_transport_adapter.dart';

/// Wi-Fi Direct transport adapter with BLE-assisted credential exchange.
///
/// This adapter wraps the existing Wi-Fi Direct host/client implementation
/// (`FlutterP2pHost` / `FlutterP2pClient`) and exposes it as a mesh transport.
///
/// Flow (fallback when Wi-Fi Aware is unavailable):
/// - One node becomes Wi-Fi Direct Group Owner (GO) and advertises SSID/PSK via BLE.
/// - Other nodes scan BLE, extract SSID/PSK, join the hotspot, and connect to the
///   WebSocket transport to exchange messages.
/// - Mesh messages are serialized as text and carried over the existing P2P
///   payload channel.
class WifiDirectBleAdapter extends MeshTransportAdapter
    with MeshTransportAdapterMixin {
  WifiDirectBleAdapter({required this.username});

  @override
  MeshTransportType get transportType => MeshTransportType.wifiDirect;

  @override
  Future<bool> get isAvailable async =>
      true; // Wi-Fi Direct is broadly available

  @override
  bool get isActive => _isHostActive || _isClientActive;

  @override
  Stream<MeshPeer> get discoveredPeers => _discoveredPeersController.stream;

  @override
  Stream<MeshPeer> get peerStateChanges => _peerStateController.stream;

  @override
  Stream<({String peerId, String data})> get incomingMessages =>
      _incomingMessagesController.stream;

  final String username;

  final FlutterP2pHost _host = FlutterP2pHost();
  final FlutterP2pClient _client = FlutterP2pClient();

  final StreamController<MeshPeer> _discoveredPeersController =
      StreamController<MeshPeer>.broadcast();
  final StreamController<MeshPeer> _peerStateController =
      StreamController<MeshPeer>.broadcast();
  final StreamController<({String peerId, String data})>
      _incomingMessagesController = StreamController.broadcast();

  final Map<String, (String ssid, String psk)> _credentialsByDevice = {};
  bool _isInitialized = false;
  bool _isHostActive = false;
  bool _isClientActive = false;

  StreamSubscription<List<BleDiscoveredDevice>>? _bleScanSub;
  StreamSubscription<BleReceivedData>? _bleDataSub;
  StreamSubscription<({String senderId, String text})>? _hostTextSub;
  StreamSubscription<({String senderId, String text})>? _clientTextSub;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    await _host.initialize();
    await _client.initialize();

    // Listen for BLE data that may contain credentials as UTF-8 JSON: {"ssid":"...","psk":"..."}
    _bleDataSub = FlutterP2pConnectionPlatform.instance
        .streamBleReceivedData()
        .listen((data) {
      _tryParseCredentials(data.deviceAddress, data.data);
    });

    _isInitialized = true;
  }

  @override
  Future<void> startDiscovery({String? serviceName}) async {
    _ensureInitialized();

    // Start BLE scan to discover hosts advertising credentials
    _bleScanSub = await _client.startScan((devices) {
      for (final d in devices) {
        _publishDiscoveredPeer(d.deviceAddress, d.deviceName);
      }
    });
  }

  @override
  Future<void> stopDiscovery() async {
    await _client.stopScan().catchError((_) {});
    await _bleScanSub?.cancel();
    _bleScanSub = null;
  }

  @override
  Future<void> startAdvertising({
    required MeshPeer localPeer,
    String? serviceName,
  }) async {
    _ensureInitialized();

    // Create Wi-Fi Direct group and advertise credentials via BLE
    final state = await _host.createGroup(advertise: true);
    _isHostActive = true;

    // Forward received text payloads into mesh incoming messages with sender ID
    _hostTextSub = _host.streamReceivedMessages().listen((event) {
      _incomingMessagesController
          .add((peerId: event.senderId, data: event.text));
    });

    // Announce self as discovered (GO)
    final peer = MeshPeer(
      id: state.hostIpAddress ?? state.ssid ?? localPeer.id,
      username: username,
      transportType: MeshTransportType.wifiDirect,
      state: MeshPeerState.connected,
      address: state.hostIpAddress,
      port: defaultP2pTransportPort,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      hopCount: 0,
    );
    updateConnectedPeer(peer);
    _peerStateController.add(peer);
  }

  @override
  Future<void> stopAdvertising() async {
    await _host.removeGroup().catchError((_) {});
    _isHostActive = false;
    await _hostTextSub?.cancel();
  }

  @override
  Future<MeshPeer> connect(String peerId) async {
    _ensureInitialized();

    final creds = _credentialsByDevice[peerId];
    if (creds == null) {
      throw MeshTransportException(
        'No Wi-Fi Direct credentials discovered for peer $peerId',
      );
    }

    await _client.connectWithCredentials(creds.$1, creds.$2);
    _isClientActive = true;

    _clientTextSub = _client.streamReceivedMessages().listen((event) {
      _incomingMessagesController
          .add((peerId: event.senderId, data: event.text));
    });

    final peer = MeshPeer(
      id: peerId,
      username: peerId,
      transportType: MeshTransportType.wifiDirect,
      state: MeshPeerState.connected,
      address: null,
      port: defaultP2pTransportPort,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      hopCount: 0,
    );
    updateConnectedPeer(peer);
    _peerStateController.add(peer);
    return peer;
  }

  @override
  Future<void> disconnect(String peerId) async {
    await _client.disconnect().catchError((_) {});
    _isClientActive = false;
    await _clientTextSub?.cancel();
    _clientTextSub = null;
    removeConnectedPeer(peerId);
    _peerStateController.add(
      MeshPeer(
        id: peerId,
        username: peerId,
        transportType: MeshTransportType.wifiDirect,
        state: MeshPeerState.disconnected,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> send(String peerId, String data) async {
    if (_isHostActive) {
      // Host: send directly to a specific client
      await _host.sendTextToClient(data, peerId);
      return;
    }

    if (_isClientActive) {
      await _client.sendTextToClient(data, peerId);
      return;
    }

    throw const MeshTransportException('No active Wi-Fi Direct transport.');
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _host.dispose().catchError((_) {});
    await _client.dispose().catchError((_) {});
    await _bleDataSub?.cancel();
    await _incomingMessagesController.close();
    await _discoveredPeersController.close();
    await _peerStateController.close();
  }

  void _publishDiscoveredPeer(String deviceAddress, String deviceName) {
    final peer = MeshPeer(
      id: deviceAddress,
      username: deviceName,
      transportType: MeshTransportType.wifiDirect,
      state: MeshPeerState.discovered,
      lastSeenAt: DateTime.now().millisecondsSinceEpoch,
    );
    updateDiscoveredPeer(peer);
    if (!_discoveredPeersController.isClosed) {
      _discoveredPeersController.add(peer);
    }
  }

  void _tryParseCredentials(String deviceAddress, List<int> data) {
    try {
      final decoded = utf8.decode(data);
      // Expect JSON: {"ssid":"...","psk":"..."}
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      final ssid = map['ssid'] as String?;
      final psk = map['psk'] as String?;
      if (ssid != null && psk != null) {
        _credentialsByDevice[deviceAddress] = (ssid, psk);
        debugPrint(
          'WifiDirectBleAdapter: captured credentials for $deviceAddress',
        );
      }
    } catch (_) {
      // Ignore parsing errors; credentials may use a different format.
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw const MeshNotInitializedException(
        'WifiDirectBleAdapter not initialized. Call initialize() first.',
      );
    }
  }
}
