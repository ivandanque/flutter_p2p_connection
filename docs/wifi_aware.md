# Wi‑Fi Aware (NAN) Support

This plugin adds Wi‑Fi Aware (Neighbor Awareness Networking) capabilities for peer discovery and mesh-style connections without a traditional Wi‑Fi AP. Use this guide to ensure your environment and app meet the requirements.

## Platform Requirements (Android)
- **OS version**: Android 8.0 (API 26) or higher.
- **Hardware**: Device must advertise `FEATURE_WIFI_AWARE`.
- **Permissions**:
  - `ACCESS_FINE_LOCATION` (and runtime grant).
  - `NEARBY_WIFI_DEVICES` on Android 12+ (runtime grant, may be marked as nearby).
  - Wi‑Fi enabled; Location services turned on.
- **SDK/Gradle**:
  - `minSdkVersion 26` (plugin enforces this).
  - `compileSdk` 33+ (project uses 34+).
  - Android Gradle Plugin 8.6.x (needed by CameraX 1.5.0 in the example app).
  - Kotlin 2.1.0 JVM target 11 (plugin and example app).
  - Java toolchain 11 (plugin and example app).

## Feature Capabilities
- **Discovery & messaging (API 26–28)**
  - Publish/subscribe service discovery.
  - Message passing between peers (small payloads, chunked when needed).
- **Data-path networking (API 29+)**
  - High-throughput socket connections over Wi‑Fi Aware data paths.
  - Per-connection PSK used when requesting a data path.
- **Mesh helpers**
  - Peer announce/track, routing, deduplication, TTL handling (see tests under `test/`).

## Integration Notes
- The plugin class is `com.ugo.studio.plugins.flutter_p2p_connection.WifiAwareManager` (Android).
- Availability broadcast: listens for `ACTION_WIFI_AWARE_STATE_CHANGED` and exposes `isWifiAwareAvailable()`/`getCapabilities()`.
- Sessions:
  - `initialize()` attaches and registers availability receiver.
  - `startDiscovery()` / `stopDiscovery()` subscribe to a service name.
  - `startAdvertising()` / `stopAdvertising()` publish a service with metadata and spin up an incoming server (data-path mode).
  - `connectToPeer()` chooses data-path (API 29+) or message-passing (API 26–28).
- Data transfer:
  - API 29+: socket I/O over Aware network.
  - API 26–28: message passing with optional chunking.
- Cleanup: `dispose()` tears down sessions, sockets, server, receivers.

## App Setup Checklist
- Set `minSdkVersion 26` (required) and `compileSdk` 34+.
- Use AGP 8.6.x, Kotlin 2.1.0, Java 11 (already set in plugin/example).
- Request and check runtime permissions:
  - Location (Fine) for all supported OS versions.
  - Nearby Wi‑Fi Devices for Android 12+.
- Ensure Wi‑Fi and Location services are ON at runtime before initializing Aware.
- Handle unavailability gracefully: hardware missing, location off, or Aware disabled.

## Host App (UsaApp) quick steps
- In UsaApp `android/app/build.gradle`: set `minSdkVersion 26`, `compileSdk` ≥34, `targetSdk` per store policy.
- Use AGP 8.6.x and Kotlin 2.1.0 (match plugin); keep Java/Kotlin toolchain at 11.
- Add/verify permissions in UsaApp `AndroidManifest.xml` and request at runtime: `ACCESS_FINE_LOCATION` (all), `NEARBY_WIFI_DEVICES` (Android 12+).
- Ensure Wi‑Fi and Location are ON before calling `initialize()`; handle `isWifiAwareAvailable()` failure states gracefully.
- For release builds, test on two Aware-capable devices (API ≥26; API ≥29 for data-path) using UsaApp flows.

## Example Build Settings (current)
- Plugin Gradle: `android/build.gradle` — AGP 8.6.1, Kotlin 2.1.0, Java 11, `compileSdk 34`, `minSdk 26`.
- Example app: `example/android/app/build.gradle` — Java/Kotlin 11, `compileSdk 36`, `minSdk 26`, `targetSdk 31` (adjust as needed), AGP 8.6.1 via `settings.gradle`.

## Testing
- Unit tests: `flutter test` (mesh router logic) — currently passing.
- Build check: `flutter build apk --debug` (example app) — currently succeeds.
- Device validation (recommended):
  ```powershell
  cd C:\FlutterProjects\flutter_p2p_connection\example
  flutter run --debug
  ```
  Test on two Aware-capable devices (API ≥26) to validate discovery and messaging; use API ≥29 devices to validate data-path sockets.

## Troubleshooting
- **Wi‑Fi Aware unavailable**: verify device supports Aware, Wi‑Fi on, Location on, permissions granted.
- **Min SDK error**: ensure `minSdkVersion` is at least 26 in your host app.
- **AGP/Kotlin version errors**: keep AGP 8.6.x and Kotlin ≥2.1.0 (or pass `--android-skip-build-dependency-validation` temporarily).
- **Permissions on Android 12+**: request `NEARBY_WIFI_DEVICES` at runtime; behavior may be gated by OEM.
- **CameraX dependency** (example app): requires AGP ≥8.6.0; already satisfied by 8.6.1.
