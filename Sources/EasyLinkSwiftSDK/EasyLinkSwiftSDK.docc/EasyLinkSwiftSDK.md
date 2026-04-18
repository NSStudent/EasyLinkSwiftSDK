# EasyLinkSwiftSDK

Discover and control Chessnut electronic chessboards over Bluetooth Low Energy.

## Overview

EasyLinkSwiftSDK is a native Swift package for communicating with Chessnut boards on iOS 16 and macOS 13 or later. It uses CoreBluetooth, exposes async APIs, and publishes realtime board positions through `AsyncStream`.

Use ``EasyLinkScanner`` when your app needs to show real Bluetooth devices in a picker. Use ``EasyLinkClient`` to connect, enable realtime updates, query battery state, set LEDs, and use Chessnut Move specific commands.

```swift
for await device in EasyLinkScanner.scan(profile: .move) {
  print(device.name)
}
```

After the user selects a device, create a client for that exact peripheral:

```swift
let client = EasyLinkClient(device: selectedDevice)
try await client.connect()
try await client.enableRealtimeUpdates()
```

## Topics

### Discovery

- <doc:DiscoveryAndConnection>
- ``EasyLinkScanner``
- ``EasyLinkDevice``
- ``BoardProfile``

### Client API

- <doc:RealtimeUpdates>
- <doc:CommandsAndResponses>
- ``EasyLinkClient``
- ``BatteryStatus``
- ``LEDBoard``
- ``LEDColor``
- ``PieceStatus``

### Integration

- <doc:CustomTransports>
- ``EasyLinkTransport``
- ``EasyLinkNotification``
- ``EasyLinkError``
