/// A Flutter plugin for establishing peer-to-peer connections
/// using Wi-Fi Direct (Group Owner/Hotspot), Wi-Fi Aware, and BLE
/// for discovery and credential exchange.
///
/// This library provides classes to act as a P2P host (`FlutterP2pHost`),
/// a P2P client (`FlutterP2pClient`), or a mesh node (`FlutterP2pMeshNode`),
/// along with necessary data models for managing connection states,
/// discovered devices, and data transfer.
///
/// ## Mesh Networking
///
/// The mesh layer (`FlutterP2pMeshNode`) enables peer-to-peer communication
/// in a mesh topology where every node can discover, connect to, and relay
/// messages for other nodes. This allows the network to grow as more peers
/// connect.
///
/// ```dart
/// final meshNode = FlutterP2pMeshNode(
///   config: MeshNodeConfig(username: 'Alice'),
/// );
/// await meshNode.start();
///
/// meshNode.onMessage.listen((message) {
///   print('From ${message.sourceUsername}: ${message.payload}');
/// });
///
/// await meshNode.broadcast(text: 'Hello, mesh!');
/// ```
library;

// Export common P2P functionalities (Host and Client)
export 'src/host/p2p_host.dart' show FlutterP2pHost;
export 'src/client/p2p_client.dart' show FlutterP2pClient;

// Export data models related to P2P connection states and BLE
export 'src/models/p2p_connection_models.dart'
    show
        HotspotHostState,
        HotspotClientState,
        BleConnectionState,
        BleDiscoveredDevice,
        BleReceivedData;

// Export data models and enums related to the P2P transport layer
export 'src/transport/common/transport_enums.dart'
    show P2pMessageType, ReceivableFileState;
export 'src/transport/common/transport_data_models.dart'
    show
        P2pClientInfo,
        P2pFileInfo,
        P2pMessagePayload,
        P2pFileProgressUpdate,
        P2pMessage;
export 'src/transport/common/transport_file_models.dart'
    show HostedFileInfo, ReceivableFileInfo, FileDownloadProgressUpdate;

// Export mesh networking layer
export 'src/mesh/flutter_p2p_mesh_node.dart'
    show FlutterP2pMeshNode, MeshNodeConfig;
export 'src/mesh/mesh_models.dart'
    show
        MeshPeer,
        MeshMessage,
        MeshDataPayload,
        MeshFileInfo,
        MeshFileChunk,
        MeshFileTransferProgress,
        MeshPeerAnnounce;
export 'src/mesh/mesh_enums.dart'
    show
        MeshMessageType,
        MeshPeerState,
        MeshTransportType,
        MeshFileTransferState;
export 'src/mesh/mesh_constants.dart';
export 'src/mesh/mesh_exceptions.dart'
    show
        MeshNotInitializedException,
        MeshPeerNotFoundException,
        MeshRoutingException,
        MeshFileTransferException,
        MeshTransportException,
        WifiAwareNotSupportedException;
export 'src/mesh/mesh_router.dart' show MeshRouter;
export 'src/mesh/adapters/mesh_transport_adapter.dart'
    show MeshTransportAdapter;
export 'src/mesh/adapters/wifi_aware_adapter.dart' show WifiAwareAdapter;
export 'src/mesh/adapters/wifi_direct_ble_adapter.dart'
    show WifiDirectBleAdapter;
