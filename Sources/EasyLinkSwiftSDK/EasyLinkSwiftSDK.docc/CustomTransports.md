# Custom Transports

Inject a transport for tests, simulators, or alternative Bluetooth stacks.

## Overview

``EasyLinkClient`` depends on ``EasyLinkTransport`` instead of CoreBluetooth directly. A transport publishes ``EasyLinkNotification`` values and implements async connect, disconnect, and write methods.

```swift
final class ReplayTransport: EasyLinkTransport {
  let notifications: AsyncStream<EasyLinkNotification>

  init() {
    self.notifications = AsyncStream { continuation in
      continuation.yield(.disconnected)
    }
  }

  func connect() async throws {}
  func disconnect() async {}
  func write(_ command: [UInt8]) async throws {}
}
```

Create the client with your transport:

```swift
let client = EasyLinkClient(profile: .move, transport: ReplayTransport())
```

Transport implementations must be `Sendable`, because the client actor stores and uses the transport across concurrency boundaries. Prefer actors or immutable value boundaries for mutable state.
