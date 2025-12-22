/// Default time-to-live for mesh messages (hop count).
const int defaultMeshTtl = 5;

/// Maximum TTL allowed for mesh messages.
const int maxMeshTtl = 15;

/// Default port for mesh transport layer.
const int defaultMeshTransportPort = 5678;

/// Interval for peer health checks.
const Duration peerHealthCheckInterval = Duration(seconds: 30);

/// Timeout for peer to be considered stale/disconnected.
const Duration peerStaleTimeout = Duration(seconds: 90);

/// Interval for broadcasting peer announcements.
const Duration peerAnnounceInterval = Duration(seconds: 15);

/// Duration to keep message IDs for deduplication.
const Duration messageDeduplicationWindow = Duration(minutes: 5);

/// Maximum number of message IDs to keep in deduplication cache.
const int maxDeduplicationCacheSize = 10000;

/// Default chunk size for file transfers (bytes).
const int defaultFileChunkSize = 65536; // 64 KB

/// Maximum concurrent file transfers per peer.
const int maxConcurrentFileTransfers = 3;
