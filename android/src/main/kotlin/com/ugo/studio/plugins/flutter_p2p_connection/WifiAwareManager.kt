package com.ugo.studio.plugins.flutter_p2p_connection

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Manages Wi-Fi Aware (NAN) operations for mesh networking.
 *
 * Wi-Fi Aware allows peer-to-peer discovery and communication without
 * requiring a traditional Wi-Fi access point or internet connection.
 *
 * Requirements:
 * - Android 8.0+ (API 26+) for basic discovery and messaging
 * - Android 10+ (API 29+) for data path networking (high-throughput connections)
 * - Device hardware support for Wi-Fi Aware
 * - Location permission (for discovery)
 * - NEARBY_WIFI_DEVICES permission (Android 12+)
 * 
 * API Level Features:
 * - API 26-28: Discovery, publish/subscribe, and message passing only
 * - API 29+: Full peer-to-peer data paths with network sockets
 */
@RequiresApi(Build.VERSION_CODES.O)
class WifiAwareManager(
    private val context: Context,
    private val methodChannel: MethodChannel
) {
    companion object {
        private const val TAG = "WifiAwareManager"
        private const val DEFAULT_SERVICE_NAME = "flutter_p2p_mesh"
        private const val DEFAULT_PORT = 5678
        
        // API 29 (Android 10) is required for data path networking
        private val SUPPORTS_DATA_PATH = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    
    private var platformAwareManager: android.net.wifi.aware.WifiAwareManager? = null
    private var wifiAwareSession: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null
    private var subscribeSession: SubscribeDiscoverySession? = null
    
    // Peer connections
    private val discoveredPeers = ConcurrentHashMap<String, PeerInfo>()
    private val connectedPeers = ConcurrentHashMap<String, PeerConnection>()
    
    // Server for incoming connections
    private var serverSocket: ServerSocket? = null
    private var isServerRunning = false
    
    private var localPeerId: String? = null
    private var localUsername: String? = null
    
    private var isInitialized = false
    private var isDiscovering = false
    private var isAdvertising = false

    // Availability broadcast receiver
    private val availabilityReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == android.net.wifi.aware.WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED) {
                val available = isWifiAwareAvailable()
                Log.d(TAG, "Wi-Fi Aware availability changed: $available")
            }
        }
    }

    /**
     * Data class representing a discovered peer.
     */
    data class PeerInfo(
        val peerId: String,
        val username: String,
        val peerHandle: PeerHandle,
        val metadata: Map<String, Any> = emptyMap()
    )

    /**
     * Data class representing an active peer connection.
     * 
     * @param peerId Unique identifier of the connected peer
     * @param network Network object (API 29+ data path only)
     * @param socket Socket for data transfer (API 29+ data path only)
     * @param inputStream Input stream for receiving data (API 29+ data path only)
     * @param outputStream Output stream for sending data (API 29+ data path only)
     * @param isConnected Whether the peer is currently connected
     * @param useMessagePassing True if using Wi-Fi Aware message passing (API 26-28)
     * @param peerHandle PeerHandle for message passing mode
     */
    data class PeerConnection(
        val peerId: String,
        val network: Network?,
        val socket: Socket?,
        val inputStream: BufferedReader?,
        val outputStream: PrintWriter?,
        var isConnected: Boolean = false,
        val useMessagePassing: Boolean = false,
        val peerHandle: PeerHandle? = null
    )

    /**
     * Checks if Wi-Fi Aware is supported and available on this device.
     */
    fun isWifiAwareAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        
        val pm = context.packageManager
        if (!pm.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) {
            Log.d(TAG, "Device does not support Wi-Fi Aware")
            return false
        }
        
        val awareManager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? android.net.wifi.aware.WifiAwareManager
        return awareManager?.isAvailable == true
    }
    
    /**
     * Gets detailed Wi-Fi Aware capabilities for this device.
     * 
     * Returns a map containing:
     * - supported: Boolean indicating if Wi-Fi Aware is supported
     * - available: Boolean indicating if Wi-Fi Aware is currently available
     * - supportsDataPath: Boolean indicating if high-throughput data path is supported (API 29+)
     * - apiLevel: Int indicating the device's API level
     * - mode: String indicating the connection mode ("data_path" or "message_passing")
     */
    fun getCapabilities(result: MethodChannel.Result) {
        val pm = context.packageManager
        val hasFeature = pm.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)
        
        val awareManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.getSystemService(Context.WIFI_AWARE_SERVICE) as? android.net.wifi.aware.WifiAwareManager
        } else null

        val isAvailable = awareManager?.isAvailable == true
        
        val capabilities = mapOf(
            "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && hasFeature),
            "available" to isAvailable,
            "supportsDataPath" to SUPPORTS_DATA_PATH,
            "apiLevel" to Build.VERSION.SDK_INT,
            "mode" to if (SUPPORTS_DATA_PATH) "data_path" else "message_passing",
            "minApiLevel" to Build.VERSION_CODES.O,
            "dataPathMinApiLevel" to Build.VERSION_CODES.Q
        )
        
        result.success(capabilities)
    }

    /**
     * Initializes the Wi-Fi Aware manager.
     */
    fun initialize(result: MethodChannel.Result) {
        if (isInitialized) {
            result.success(null)
            return
        }

        if (!isWifiAwareAvailable()) {
            result.error("WIFI_AWARE_UNAVAILABLE", "Wi-Fi Aware is not available on this device", null)
            return
        }

        try {
            platformAwareManager = context.getSystemService(Context.WIFI_AWARE_SERVICE) as android.net.wifi.aware.WifiAwareManager

            // Register for availability changes
            val filter = IntentFilter(android.net.wifi.aware.WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED)
            context.registerReceiver(availabilityReceiver, filter)

            // Attach to Wi-Fi Aware
            platformAwareManager?.attach(object : android.net.wifi.aware.AttachCallback() {
                override fun onAttached(session: android.net.wifi.aware.WifiAwareSession) {
                    Log.d(TAG, "Wi-Fi Aware attached successfully")
                    wifiAwareSession = session
                    isInitialized = true
                    mainHandler.post { result.success(null) }
                }

                override fun onAttachFailed() {
                    Log.e(TAG, "Wi-Fi Aware attach failed")
                    mainHandler.post {
                        result.error("ATTACH_FAILED", "Failed to attach to Wi-Fi Aware", null)
                    }
                }
            }, mainHandler)
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing Wi-Fi Aware", e)
            result.error("INIT_ERROR", "Failed to initialize Wi-Fi Aware: ${e.message}", null)
        }
    }

    /**
     * Starts discovering nearby Wi-Fi Aware peers.
     */
    fun startDiscovery(serviceName: String?, result: MethodChannel.Result) {
        if (!isInitialized || wifiAwareSession == null) {
            result.error("NOT_INITIALIZED", "Wi-Fi Aware is not initialized", null)
            return
        }

        if (isDiscovering) {
            result.success(null)
            return
        }

        val service = serviceName ?: DEFAULT_SERVICE_NAME

        val subscribeConfig = SubscribeConfig.Builder()
            .setServiceName(service)
            .build()

        wifiAwareSession?.subscribe(subscribeConfig, object : DiscoverySessionCallback() {
            override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
                Log.d(TAG, "Subscribe started for service: $service")
                subscribeSession = session
                isDiscovering = true
                mainHandler.post { result.success(null) }
            }

            override fun onServiceDiscovered(
                peerHandle: PeerHandle,
                serviceSpecificInfo: ByteArray?,
                matchFilter: MutableList<ByteArray>?
            ) {
                val peerData = parseServiceInfo(serviceSpecificInfo)
                val peerId = peerData["peerId"] as? String ?: peerHandle.hashCode().toString()
                val username = peerData["username"] as? String ?: "Unknown"
                
                val peerInfo = PeerInfo(
                    peerId = peerId,
                    username = username,
                    peerHandle = peerHandle,
                    metadata = peerData
                )
                
                discoveredPeers[peerId] = peerInfo
                
                Log.d(TAG, "Discovered peer: $username ($peerId)")
                
                mainHandler.post {
                    methodChannel.invokeMethod("onPeerDiscovered", mapOf(
                        "peerId" to peerId,
                        "username" to username,
                        "metadata" to peerData
                    ))
                }
            }

            override fun onServiceLost(peerHandle: PeerHandle, reason: Int) {
                val peerId = discoveredPeers.entries
                    .find { it.value.peerHandle == peerHandle }?.key
                
                if (peerId != null) {
                    discoveredPeers.remove(peerId)
                    Log.d(TAG, "Lost peer: $peerId")
                    
                    mainHandler.post {
                        methodChannel.invokeMethod("onPeerLost", peerId)
                    }
                }
            }
            
            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray?) {
                // Handle incoming messages (ACK, data for API 26-28)
                handleIncomingMessage(peerHandle, message)
            }

            override fun onSessionTerminated() {
                Log.d(TAG, "Subscribe session terminated")
                isDiscovering = false
                subscribeSession = null
            }
        }, mainHandler)
    }

    /**
     * Stops peer discovery.
     */
    fun stopDiscovery(result: MethodChannel.Result) {
        subscribeSession?.close()
        subscribeSession = null
        isDiscovering = false
        result.success(null)
    }

    /**
     * Starts advertising this device for discovery by others.
     */
    fun startAdvertising(
        serviceName: String?,
        peerId: String,
        username: String,
        metadata: Map<String, Any>?,
        result: MethodChannel.Result
    ) {
        if (!isInitialized || wifiAwareSession == null) {
            result.error("NOT_INITIALIZED", "Wi-Fi Aware is not initialized", null)
            return
        }

        if (isAdvertising) {
            result.success(null)
            return
        }

        localPeerId = peerId
        localUsername = username

        val service = serviceName ?: DEFAULT_SERVICE_NAME
        val serviceInfo = createServiceInfo(peerId, username, metadata)

        val publishConfig = PublishConfig.Builder()
            .setServiceName(service)
            .setServiceSpecificInfo(serviceInfo)
            .build()

        wifiAwareSession?.publish(publishConfig, object : DiscoverySessionCallback() {
            override fun onPublishStarted(session: PublishDiscoverySession) {
                Log.d(TAG, "Publish started for service: $service")
                publishSession = session
                isAdvertising = true
                
                // Start server for incoming connections
                startServer()
                
                mainHandler.post { result.success(null) }
            }

            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray?) {
                // Handle incoming connection requests
                handleIncomingMessage(peerHandle, message)
            }

            override fun onSessionTerminated() {
                Log.d(TAG, "Publish session terminated")
                isAdvertising = false
                publishSession = null
            }
        }, mainHandler)
    }

    /**
     * Stops advertising.
     */
    fun stopAdvertising(result: MethodChannel.Result) {
        publishSession?.close()
        publishSession = null
        isAdvertising = false
        stopServer()
        result.success(null)
    }

    /**
     * Connects to a discovered peer.
     * 
     * On API 29+ (Android 10+): Uses Wi-Fi Aware data path for high-throughput socket connections.
     * On API 26-28 (Android 8-9): Uses message-based communication only (limited throughput).
     */
    fun connectToPeer(peerId: String, result: MethodChannel.Result) {
        val peerInfo = discoveredPeers[peerId]
        if (peerInfo == null) {
            result.error("PEER_NOT_FOUND", "Peer $peerId not found", null)
            return
        }

        // Send connection request message
        val connectionRequest = "CONNECT:${localPeerId}:${localUsername}".toByteArray()
        
        subscribeSession?.sendMessage(
            peerInfo.peerHandle,
            0,
            connectionRequest
        )

        // Request network for data path (API 29+ only)
        if (SUPPORTS_DATA_PATH) {
            requestNetwork(peerInfo, result)
        } else {
            // For API 26-28, use message-based communication
            connectViaMessagePassing(peerInfo, result)
        }
    }

    /**
     * Disconnects from a peer.
     */
    fun disconnectPeer(peerId: String, result: MethodChannel.Result) {
        val connection = connectedPeers.remove(peerId)
        if (connection != null) {
            try {
                connection.socket?.close()
                connection.inputStream?.close()
                connection.outputStream?.close()
            } catch (e: Exception) {
                Log.e(TAG, "Error disconnecting from peer $peerId", e)
            }
        }
        result.success(null)
    }

    /**
     * Sends data to a connected peer.
     * 
     * Uses socket-based transfer on API 29+ or message passing on API 26-28.
     */
    fun sendData(peerId: String, data: String, result: MethodChannel.Result) {
        val connection = connectedPeers[peerId]
        if (connection == null || !connection.isConnected) {
            result.error("NOT_CONNECTED", "Peer $peerId is not connected", null)
            return
        }

        if (connection.useMessagePassing) {
            // API 26-28: Send via Wi-Fi Aware message passing
            sendDataViaMessagePassing(connection, data, result)
        } else {
            // API 29+: Send via socket
            sendDataViaSocket(connection, data, result)
        }
    }
    
    /**
     * Sends data via Wi-Fi Aware message passing (API 26-28).
     * Note: Messages are limited to ~255 bytes per message.
     */
    private fun sendDataViaMessagePassing(connection: PeerConnection, data: String, result: MethodChannel.Result) {
        val peerHandle = connection.peerHandle
        if (peerHandle == null) {
            result.error("NO_PEER_HANDLE", "Peer handle not available for message passing", null)
            return
        }
        
        // Wi-Fi Aware messages are limited in size, chunk if necessary
        val maxMessageSize = 255
        val messageBytes = "DATA:$data".toByteArray(Charsets.UTF_8)
        
        if (messageBytes.size > maxMessageSize) {
            // For large messages, we need to chunk them
            val chunks = messageBytes.toList().chunked(maxMessageSize - 10) // Reserve bytes for header
            var chunkIndex = 0
            
            for (chunk in chunks) {
                val header = "CHUNK:${chunkIndex}:${chunks.size}:".toByteArray(Charsets.UTF_8)
                val chunkMessage = header + chunk.toByteArray()
                
                val session = publishSession ?: subscribeSession
                session?.sendMessage(peerHandle, chunkIndex, chunkMessage)
                chunkIndex++
            }
        } else {
            val session = publishSession ?: subscribeSession
            session?.sendMessage(peerHandle, 0, messageBytes)
        }
        
        mainHandler.post { result.success(null) }
    }
    
    /**
     * Sends data via socket (API 29+).
     */
    private fun sendDataViaSocket(connection: PeerConnection, data: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                connection.outputStream?.println(data)
                connection.outputStream?.flush()
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "Error sending data to ${connection.peerId}", e)
                mainHandler.post {
                    result.error("SEND_ERROR", "Failed to send data: ${e.message}", null)
                }
            }
        }
    }

    /**
     * Disposes all resources.
     */
    fun dispose(result: MethodChannel.Result) {
        disposeInternal()
        result.success(null)
    }
    
    /**
     * Disposes all resources without a result callback.
     */
    fun dispose() {
        disposeInternal()
    }
    
    private fun disposeInternal() {
        try {
            context.unregisterReceiver(availabilityReceiver)
        } catch (e: Exception) {
            // Receiver may not be registered
        }

        stopServer()
        
        // Close all peer connections
        connectedPeers.values.forEach { connection ->
            try {
                connection.socket?.close()
            } catch (e: Exception) {}
        }
        connectedPeers.clear()
        discoveredPeers.clear()
        pendingChunks.clear()

        subscribeSession?.close()
        publishSession?.close()
        wifiAwareSession?.close()

        subscribeSession = null
        publishSession = null
        wifiAwareSession = null
        isInitialized = false
        isDiscovering = false
        isAdvertising = false
    }

    // --- Private Helper Methods ---

    /**
     * For API 26-28: Establishes connection using Wi-Fi Aware message passing.
     * This method provides limited throughput compared to data path networking.
     */
    private fun connectViaMessagePassing(peerInfo: PeerInfo, result: MethodChannel.Result) {
        Log.d(TAG, "Using message-based connection for API ${Build.VERSION.SDK_INT} (data path requires API 29+)")
        
        // Create a message-based "connection" 
        val connection = PeerConnection(
            peerId = peerInfo.peerId,
            network = null,
            socket = null,
            inputStream = null,
            outputStream = null,
            isConnected = true,
            useMessagePassing = true,
            peerHandle = peerInfo.peerHandle
        )
        
        connectedPeers[peerInfo.peerId] = connection
        
        mainHandler.post {
            result.success(mapOf(
                "address" to null,
                "port" to null,
                "mode" to "message_passing"
            ))
            
            methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                "peerId" to peerInfo.peerId,
                "state" to "connected",
                "mode" to "message_passing"
            ))
        }
    }

    /**
     * For API 29+: Requests a Wi-Fi Aware network for high-throughput data path connection.
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun requestNetwork(peerInfo: PeerInfo, result: MethodChannel.Result) {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val networkSpecifier = WifiAwareNetworkSpecifier.Builder(subscribeSession!!, peerInfo.peerHandle)
            .setPskPassphrase("flutter_p2p_mesh_psk") // Use a secure passphrase
            .build()

        val networkRequest = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(networkSpecifier)
            .build()

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.d(TAG, "Network available for peer ${peerInfo.peerId}")
                
                executor.execute {
                    try {
                        // Connect via socket
                        val socket = network.socketFactory.createSocket(
                            peerInfo.peerHandle.hashCode().toString(),
                            DEFAULT_PORT
                        )
                        
                        val connection = PeerConnection(
                            peerId = peerInfo.peerId,
                            network = network,
                            socket = socket,
                            inputStream = BufferedReader(InputStreamReader(socket.getInputStream())),
                            outputStream = PrintWriter(socket.getOutputStream(), true),
                            isConnected = true
                        )
                        
                        connectedPeers[peerInfo.peerId] = connection
                        
                        // Start listening for incoming data
                        startListening(connection)
                        
                        mainHandler.post {
                            result.success(mapOf(
                                "address" to socket.inetAddress?.hostAddress,
                                "port" to socket.port
                            ))
                            
                            methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                                "peerId" to peerInfo.peerId,
                                "state" to "connected",
                                "address" to socket.inetAddress?.hostAddress,
                                "port" to socket.port
                            ))
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error connecting to peer ${peerInfo.peerId}", e)
                        mainHandler.post {
                            result.error("CONNECTION_ERROR", "Failed to connect: ${e.message}", null)
                        }
                    }
                }
            }

            override fun onLost(network: Network) {
                Log.d(TAG, "Network lost for peer ${peerInfo.peerId}")
                
                val connection = connectedPeers.remove(peerInfo.peerId)
                connection?.let {
                    try {
                        it.socket?.close()
                    } catch (e: Exception) {}
                }
                
                mainHandler.post {
                    methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                        "peerId" to peerInfo.peerId,
                        "state" to "disconnected"
                    ))
                }
            }

            override fun onUnavailable() {
                Log.e(TAG, "Network unavailable for peer ${peerInfo.peerId}")
                mainHandler.post {
                    result.error("NETWORK_UNAVAILABLE", "Network unavailable", null)
                }
            }
        }

        connectivityManager.requestNetwork(networkRequest, networkCallback)
    }

    private fun startServer() {
        if (isServerRunning) return
        
        executor.execute {
            try {
                serverSocket = ServerSocket(DEFAULT_PORT)
                isServerRunning = true
                Log.d(TAG, "Server started on port $DEFAULT_PORT")
                
                while (isServerRunning) {
                    try {
                        val clientSocket = serverSocket?.accept() ?: break
                        handleIncomingConnection(clientSocket)
                    } catch (e: Exception) {
                        if (isServerRunning) {
                            Log.e(TAG, "Error accepting connection", e)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting server", e)
            }
        }
    }

    private fun stopServer() {
        isServerRunning = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {}
        serverSocket = null
    }

    private fun handleIncomingConnection(socket: Socket) {
        executor.execute {
            try {
                val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                val writer = PrintWriter(socket.getOutputStream(), true)
                
                // Read peer ID from first message
                val firstMessage = reader.readLine()
                val peerId = firstMessage?.substringAfter("PEER_ID:") ?: socket.inetAddress.hostAddress ?: "unknown"
                
                val connection = PeerConnection(
                    peerId = peerId,
                    network = null,
                    socket = socket,
                    inputStream = reader,
                    outputStream = writer,
                    isConnected = true
                )
                
                connectedPeers[peerId] = connection
                
                mainHandler.post {
                    methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                        "peerId" to peerId,
                        "state" to "connected",
                        "address" to socket.inetAddress?.hostAddress,
                        "port" to socket.port
                    ))
                }
                
                startListening(connection)
            } catch (e: Exception) {
                Log.e(TAG, "Error handling incoming connection", e)
            }
        }
    }

    private fun startListening(connection: PeerConnection) {
        executor.execute {
            try {
                while (connection.isConnected && connection.socket?.isConnected == true) {
                    val data = connection.inputStream?.readLine()
                    if (data != null) {
                        mainHandler.post {
                            methodChannel.invokeMethod("onDataReceived", mapOf(
                                "peerId" to connection.peerId,
                                "data" to data
                            ))
                        }
                    } else {
                        // Connection closed
                        break
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error reading from peer ${connection.peerId}", e)
            } finally {
                connection.isConnected = false
                connectedPeers.remove(connection.peerId)
                
                mainHandler.post {
                    methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                        "peerId" to connection.peerId,
                        "state" to "disconnected"
                    ))
                }
            }
        }
    }

    private fun handleIncomingMessage(peerHandle: PeerHandle, message: ByteArray?) {
        val messageStr = message?.toString(Charsets.UTF_8) ?: return
        Log.d(TAG, "Received message: ${messageStr.take(50)}...")
        
        when {
            messageStr.startsWith("CONNECT:") -> {
                val parts = messageStr.split(":")
                if (parts.size >= 3) {
                    val peerId = parts[1]
                    val username = parts[2]
                    
                    val peerInfo = PeerInfo(
                        peerId = peerId,
                        username = username,
                        peerHandle = peerHandle
                    )
                    discoveredPeers[peerId] = peerInfo
                    
                    // Send acknowledgment
                    publishSession?.sendMessage(
                        peerHandle,
                        0,
                        "ACK:${localPeerId}:${localUsername}".toByteArray()
                    )
                    
                    // For API 26-28, auto-accept incoming connections via message passing
                    if (!SUPPORTS_DATA_PATH) {
                        val connection = PeerConnection(
                            peerId = peerId,
                            network = null,
                            socket = null,
                            inputStream = null,
                            outputStream = null,
                            isConnected = true,
                            useMessagePassing = true,
                            peerHandle = peerHandle
                        )
                        connectedPeers[peerId] = connection
                        
                        mainHandler.post {
                            methodChannel.invokeMethod("onConnectionStateChanged", mapOf(
                                "peerId" to peerId,
                                "state" to "connected",
                                "mode" to "message_passing"
                            ))
                        }
                    }
                }
            }
            messageStr.startsWith("DATA:") -> {
                // Handle data message (API 26-28 message passing mode)
                val data = messageStr.removePrefix("DATA:")
                val senderId = findPeerIdByHandle(peerHandle)
                
                if (senderId != null) {
                    mainHandler.post {
                        methodChannel.invokeMethod("onDataReceived", mapOf(
                            "peerId" to senderId,
                            "data" to data
                        ))
                    }
                }
            }
            messageStr.startsWith("CHUNK:") -> {
                // Handle chunked data message (API 26-28 message passing mode)
                handleChunkedMessage(peerHandle, messageStr)
            }
            messageStr.startsWith("ACK:") -> {
                // Handle acknowledgment from publisher (subscriber receives this)
                Log.d(TAG, "Received ACK from publisher")
                // The connection is already established via connectViaMessagePassing
            }
        }
    }
    
    /**
     * Finds a peer ID by their PeerHandle.
     */
    private fun findPeerIdByHandle(peerHandle: PeerHandle): String? {
        return connectedPeers.entries.find { 
            it.value.peerHandle?.hashCode() == peerHandle.hashCode() 
        }?.key ?: discoveredPeers.entries.find { 
            it.value.peerHandle.hashCode() == peerHandle.hashCode() 
        }?.key
    }
    
    /**
     * Handles chunked messages for large data transfers in message passing mode.
     */
    private val pendingChunks = mutableMapOf<String, MutableList<ByteArray>>()
    
    private fun handleChunkedMessage(peerHandle: PeerHandle, messageStr: String) {
        val parts = messageStr.split(":", limit = 4)
        if (parts.size < 4) return
        
        val chunkIndex = parts[1].toIntOrNull() ?: return
        val totalChunks = parts[2].toIntOrNull() ?: return
        val chunkData = parts[3].toByteArray(Charsets.UTF_8)
        
        val senderId = findPeerIdByHandle(peerHandle) ?: return
        val key = "$senderId:$totalChunks"
        
        val chunks = pendingChunks.getOrPut(key) { MutableList(totalChunks) { ByteArray(0) } }
        
        if (chunkIndex < chunks.size) {
            chunks[chunkIndex] = chunkData
        }
        
        // Check if all chunks received
        if (chunks.none { it.isEmpty() }) {
            val fullData = chunks.flatMap { it.toList() }.toByteArray().toString(Charsets.UTF_8)
            pendingChunks.remove(key)
            
            mainHandler.post {
                methodChannel.invokeMethod("onDataReceived", mapOf(
                    "peerId" to senderId,
                    "data" to fullData
                ))
            }
        }
    }

    private fun createServiceInfo(peerId: String, username: String, metadata: Map<String, Any>?): ByteArray {
        val info = StringBuilder()
        info.append("peerId=$peerId")
        info.append(";username=$username")
        metadata?.forEach { (key, value) ->
            info.append(";$key=$value")
        }
        return info.toString().toByteArray()
    }

    private fun parseServiceInfo(data: ByteArray?): Map<String, Any> {
        if (data == null) return emptyMap()
        
        val result = mutableMapOf<String, Any>()
        val infoStr = data.toString(Charsets.UTF_8)
        
        infoStr.split(";").forEach { part ->
            val keyValue = part.split("=", limit = 2)
            if (keyValue.size == 2) {
                result[keyValue[0]] = keyValue[1]
            }
        }
        
        return result
    }
}
