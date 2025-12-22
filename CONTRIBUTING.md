# Contributing to flutter_p2p_connection

Thank you for your interest in contributing! This document outlines the coding standards and conventions used in this project.

---

## Code Style & Conventions

### General Dart/Flutter Standards

- Follow the official [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style).
- Use `flutter_lints` (configured in `analysis_options.yaml`) for static analysis.
- Run `dart format .` before committing.

### File Organization

```
lib/
├── flutter_p2p_connection.dart          # Main library file with exports
├── flutter_p2p_connection_platform_interface.dart
├── flutter_p2p_connection_method_channel.dart
└── src/
    ├── client/                          # P2P client implementations
    ├── host/                            # P2P host implementations
    ├── mesh/                            # Mesh networking layer
    ├── models/                          # Data models (shared)
    ├── common/                          # Shared utilities, base classes, constants
    └── transport/
        ├── common/                      # Shared transport models & enums
        ├── client/                      # Client transport layer
        ├── host/                        # Host transport layer
        └── adapters/                    # Transport adapters (WiFiAware, BLE, etc.)
```

### Naming Conventions

| Element              | Convention                  | Example                            |
|----------------------|-----------------------------|------------------------------------|
| Files                | `snake_case.dart`           | `mesh_router.dart`                 |
| Classes              | `UpperCamelCase`            | `FlutterP2pMeshNode`               |
| Enums                | `UpperCamelCase`            | `MeshMessageType`                  |
| Enum values          | `lowerCamelCase`            | `MeshMessageType.routeRequest`     |
| Variables/fields     | `lowerCamelCase`            | `final String messageId;`          |
| Private members      | `_lowerCamelCase`           | `final Map<String, MeshPeer> _peers;` |
| Constants            | `lowerCamelCase`            | `const int defaultMeshTtl = 5;`    |
| Type parameters      | Single uppercase letter     | `<T>`, `<K, V>`                    |

### Class Structure

Follow this order within classes:

1. **Static constants**
2. **Final fields** (public, then private)
3. **Mutable fields** (public, then private)
4. **Constructors** (unnamed first, then named, then factory)
5. **Getters/setters**
6. **Public methods**
7. **Private methods**
8. **Overrides** (`toString`, `==`, `hashCode`)

### Documentation Comments

- Use `///` for documentation comments on all public APIs.
- Include parameter descriptions using `[paramName]` syntax.
- Provide examples for complex APIs.

```dart
/// Sends a message to one or more peers in the mesh network.
///
/// The [message] will be routed through intermediate nodes if the target
/// peers are not directly connected. Messages are deduplicated using
/// [MeshMessage.id] to prevent routing loops.
///
/// - [targetPeerIds]: List of peer IDs to send the message to.
///   If empty, the message is broadcast to all reachable peers.
/// - [ttl]: Time-to-live (hop count). Defaults to [defaultMeshTtl].
///
/// Throws [MeshNotInitializedException] if the node is not started.
Future<void> sendMessage(
  MeshMessage message, {
  List<String> targetPeerIds = const [],
  int? ttl,
});
```

### Immutable Models

- Use `@immutable` annotation for data classes.
- Prefer `final` fields.
- Implement `fromJson`/`toJson` factory constructors and methods.
- Override `==`, `hashCode`, and `toString`.

```dart
import 'package:flutter/foundation.dart';

/// Represents a peer in the mesh network.
@immutable
class MeshPeer {
  /// Unique identifier for the peer.
  final String id;

  /// Display name of the peer.
  final String username;

  /// Unix timestamp of last activity (milliseconds since epoch).
  final int lastSeenAt;

  /// Creates a [MeshPeer] instance.
  const MeshPeer({
    required this.id,
    required this.username,
    required this.lastSeenAt,
  });

  /// Creates a [MeshPeer] from a JSON map.
  factory MeshPeer.fromJson(Map<String, dynamic> json) {
    return MeshPeer(
      id: json['id'] as String,
      username: json['username'] as String,
      lastSeenAt: json['lastSeenAt'] as int,
    );
  }

  /// Converts this [MeshPeer] to a JSON map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'lastSeenAt': lastSeenAt,
      };

  @override
  String toString() => 'MeshPeer(id: $id, username: $username)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshPeer &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          username == other.username &&
          lastSeenAt == other.lastSeenAt;

  @override
  int get hashCode => Object.hash(id, username, lastSeenAt);
}
```

### Enums

- Place enums in dedicated files under `transport/common/` or `mesh/`.
- Document each enum value.

```dart
/// Enum representing the type of a mesh message.
enum MeshMessageType {
  /// A data payload (text, files, or custom data).
  data,

  /// Peer discovery announcement.
  peerAnnounce,

  /// Request for routing information.
  routeRequest,

  /// Response with routing information.
  routeResponse,

  /// Acknowledgment of received message.
  ack,

  /// Unknown or unsupported message type.
  unknown,
}
```

### Error Handling

- Create custom exception classes for domain-specific errors.
- Use descriptive error messages.
- Document thrown exceptions in method doc comments.

```dart
/// Exception thrown when a mesh operation is attempted before initialization.
class MeshNotInitializedException implements Exception {
  final String message;
  const MeshNotInitializedException([this.message = 'Mesh node not initialized.']);

  @override
  String toString() => 'MeshNotInitializedException: $message';
}
```

### Logging

- Use `debugPrint()` for debug logging (Flutter-safe, throttled).
- Include a consistent prefix for log messages: `"MeshRouter [$username]: ..."`.

```dart
debugPrint("MeshRouter [$username]: Forwarding message ${message.id} to ${nextHop.id}");
```

### Async Patterns

- Use `Future<T>` for one-shot async operations.
- Use `Stream<T>` for ongoing event streams.
- Use `StreamController<T>.broadcast()` for multi-listener streams.
- Always handle stream errors and cleanup in `dispose()`.

```dart
final StreamController<MeshMessage> _messageController =
    StreamController<MeshMessage>.broadcast();

Stream<MeshMessage> get messageStream => _messageController.stream;

Future<void> dispose() async {
  await _messageController.close();
}
```

### Constants

- Define related constants in a dedicated file (e.g., `mesh_constants.dart`).
- Use `const` for compile-time constants.

```dart
/// Default time-to-live for mesh messages (hop count).
const int defaultMeshTtl = 5;

/// Default port for mesh transport.
const int defaultMeshTransportPort = 5678;

/// Interval for peer health checks.
const Duration peerHealthCheckInterval = Duration(seconds: 30);
```

---

## Testing

- Place unit tests in `test/`.
- Name test files with `_test.dart` suffix.
- Group related tests using `group()`.
- Use descriptive test names.

```dart
void main() {
  group('MeshRouter', () {
    test('should deduplicate messages by ID', () {
      // ...
    });

    test('should decrement TTL and drop at zero', () {
      // ...
    });
  });
}
```

---

## Platform Code (Android/Kotlin)

- Follow [Kotlin Coding Conventions](https://kotlinlang.org/docs/coding-conventions.html).
- Place Android-specific code in `android/src/main/kotlin/`.
- Use suspend functions for async operations.
- Handle permissions and API level checks gracefully.

---

## Pull Request Checklist

- [ ] Code follows the style guide above.
- [ ] All public APIs are documented with `///` comments.
- [ ] Unit tests added/updated for new functionality.
- [ ] `dart format .` has been run.
- [ ] `flutter analyze` passes with no errors.
- [ ] Example app updated if public API changed.
- [ ] CHANGELOG.md updated.

---

## Questions?

Open an issue or reach out to the maintainers. Happy coding!
