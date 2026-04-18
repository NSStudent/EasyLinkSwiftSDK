# EasyLinkSwiftSDK

[![Checks](https://github.com/NSStudent/EasyLinkSwiftSDK/actions/workflows/check.yml/badge.svg)](https://github.com/NSStudent/EasyLinkSwiftSDK/actions/workflows/check.yml)
[![codecov](https://codecov.io/gh/NSStudent/EasyLinkSwiftSDK/branch/main/graph/badge.svg)](https://codecov.io/gh/NSStudent/EasyLinkSwiftSDK)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg?logo=swift)](https://www.swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://www.swift.org/package-manager/)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013-lightgrey.svg)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FNSStudent%2FEasyLinkSwiftSDK%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/NSStudent/EasyLinkSwiftSDK)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FNSStudent%2FEasyLinkSwiftSDK%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/NSStudent/EasyLinkSwiftSDK)

`EasyLinkSwiftSDK` is a native Swift package for discovering and communicating with [Chessnut](https://www.chessnutech.com) electronic chessboards over Bluetooth Low Energy.

The package targets iOS 16 and macOS 13, uses CoreBluetooth directly, and exposes a Swift Concurrency-first API with `async/await`, `actor` isolation, `Sendable` models, and `AsyncStream` realtime updates. It does not vendor or wrap the original C/C++ EasyLink SDK.

## Features

- Discover real Bluetooth peripherals with their advertised name and CoreBluetooth identifier.
- Connect to a selected board instead of blindly connecting to the first matching peripheral.
- Receive realtime board positions as FEN placement strings through `AsyncStream`.
- Query battery status.
- Control LEDs for classic Chessnut boards and Chessnut Move.
- Use Chessnut Move auto-move, stop auto-move, and piece-status commands.
- Inject custom transports for tests, simulators, replay tools, or alternative BLE stacks.
- Generate DocC documentation for public API and usage guides.

## Supported Boards

| SDK profile | Boards |
| --- | --- |
| `BoardProfile.classic` | Chessnut Air, Air+, Go, Pro style BLE profile |
| `BoardProfile.move` | Chessnut Move |

Both profiles use the standard Chessnut BLE services and characteristics:

| Purpose | UUID |
| --- | --- |
| FEN service | `1b7e8261-2877-41c3-b46e-cf057c562023` |
| FEN notification characteristic | `1b7e8262-2877-41c3-b46e-cf057c562023` |
| Operation service | `1b7e8271-2877-41c3-b46e-cf057c562023` |
| Command characteristic | `1b7e8272-2877-41c3-b46e-cf057c562023` |
| Response characteristic | `1b7e8273-2877-41c3-b46e-cf057c562023` |

## Swift Package Manager

Add the package dependency:

```swift
.package(url: "https://github.com/NSStudent/EasyLinkSwiftSDK.git", from: "0.1.0")
```

Then add the product to your target:

```swift
.target(
  name: "YourTarget",
  dependencies: [
    .product(name: "EasyLinkSwiftSDK", package: "EasyLinkSwiftSDK")
  ]
)
```

## Documentation

The generated DocC documentation is published at:

[https://nsstudent.dev/EasyLinkSwiftSDK/documentation/easylinkswiftsdk/](https://nsstudent.dev/EasyLinkSwiftSDK/documentation/easylinkswiftsdk/)

The source DocC catalog lives in:

```text
Sources/EasyLinkSwiftSDK/EasyLinkSwiftSDK.docc
```

You can generate it locally with:

```sh
xcodebuild -scheme EasyLinkSwiftSDK \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/EasyLinkSwiftSDKDerivedData \
  docbuild
```

For the static site used by releases:

```sh
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target EasyLinkSwiftSDK \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path EasyLinkSwiftSDK/ \
  --output-path ./docs
```

## Basic Usage

### Discover Boards

Use `EasyLinkScanner` to show the user real Bluetooth devices and their advertised names:

```swift
import EasyLinkSwiftSDK

let scanTask = Task {
  for await device in EasyLinkScanner.scan(profile: .move) {
    print("Found:", device.name, device.id)
  }
}
```

Cancel the scan when the picker closes:

```swift
scanTask.cancel()
```

### Connect to a Selected Device

After the user chooses a board, connect to that exact peripheral:

```swift
let client = EasyLinkClient(device: selectedDevice)

try await client.connect()
try await client.enableRealtimeUpdates()
```

If you have stored only the CoreBluetooth identifier:

```swift
let client = EasyLinkClient(profile: .move, deviceID: storedPeripheralID)
try await client.connect()
```

### Read Realtime FEN Updates

`fenUpdates` emits only the placement field of a FEN string:

```swift
Task {
  for await placement in client.fenUpdates {
    print("Board:", placement)
  }
}
```

Example placement:

```text
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR
```

The SDK does not infer side to move, castling rights, en passant target, halfmove clock, or fullmove number.

### Query Battery

```swift
let status = try await client.batteryStatus(timeout: .seconds(5))
print("Battery:", status.percentage)

if let isCharging = status.isCharging {
  print(isCharging ? "Charging" : "Not charging")
}
```

### Set LEDs

```swift
var leds = LEDBoard.allOff
leds[rankIndex: 6, fileIndex: 4] = .red
leds[rankIndex: 7, fileIndex: 4] = .blue

try await client.setLEDs(leds)
```

Classic boards treat every non-`.off` value as an enabled monochrome LED. Chessnut Move preserves supported color values.

### Chessnut Move Auto-Move

```swift
try await client.setAutoMove(
  fen: "8/8/8/3k4/4K3/8/8/8",
  force: true
)

try await client.stopAutoMove()
```

### Chessnut Move Piece Status

```swift
let pieces = try await client.pieceStatus()

for piece in pieces {
  print(piece.index, piece.piece, piece.x, piece.y, piece.batteryPercentage)
}
```

## Custom Transports

`EasyLinkClient` depends on `EasyLinkTransport`, so tests and simulators can replace CoreBluetooth:

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

let client = EasyLinkClient(profile: .move, transport: ReplayTransport())
```

Transport implementations must be `Sendable`, because the client actor stores and uses them across concurrency boundaries.

## Protocol Notes

FEN notifications are decoded using the same nibble mapping as the C++ SDK's `ChessLink::toFen`: board payload bytes `[2]...[33]`, two squares per byte, and the piece table `["", "q", "k", "b", "p", "n", "R", "P", "r", "B", "N", "Q", "K"]`.

Common realtime command:

- Enable realtime FEN: `[0x21, 0x01, 0x00]`

Classic profile:

- LEDs: `[0x0A, 0x08, ...8 bytes...]`
- Battery request: `[0x29, 0x01, 0x00]`
- Battery response: `[0x2A, 0x02, batteryLevel, reserved]`

Chessnut Move profile:

- Auto-move FEN: `[0x42, 0x21, ...32 board bytes..., forceFlag]`
- Stop auto-move: `[0x42, 0x21, ...33 zero bytes...]`
- Color LEDs: `[0x43, 0x20, ...32 LED bytes...]`
- Battery request: `[0x41, 0x01, 0x0C]`
- Battery response: `[0x41, 0x03, 0x0C, charging, batteryLevel]`
- Piece status request: `[0x41, 0x01, 0x0B]`
- Piece status response: `[0x41, 0x89, 0x0B, ...34 four-byte piece records...]`

## Roadmap

### Done

- [x] Native Swift Package Manager library.
- [x] Swift 6 language mode.
- [x] Strict-concurrency-safe public client using actor isolation.
- [x] `Sendable` public models and transport contract.
- [x] CoreBluetooth transport.
- [x] Public scanner API with real peripheral names and identifiers.
- [x] Connection to a selected Bluetooth device by `EasyLinkDevice` or `deviceID`.
- [x] Realtime FEN updates with `AsyncStream`.
- [x] Classic and Chessnut Move LED commands.
- [x] Battery status query for supported profiles.
- [x] Chessnut Move auto-move and stop auto-move commands.
- [x] Chessnut Move piece-status parsing.
- [x] Bounded response buffering in the internal response router.
- [x] Unit tests for codec, client flows, response routing, and strict concurrency builds.
- [x] GitHub Actions for tests, coverage, release, and DocC publishing.
- [x] DocC catalog with API documentation and usage guides.

### Next Steps

- [ ] Add configurable `connect()` timeout for scan, connection, and service discovery.
- [ ] Filter scans by BLE services when practical to reduce discovery noise and power usage.
- [ ] Surface invalid FEN notification errors through a diagnostic stream or logging hook.
- [ ] Add typed square, rank, and file models instead of raw `Int` indexes in `LEDBoard`.
- [ ] Add safe LED board read/write helpers with bounds validation.
- [ ] Expand LED colors or brightness controls if newer hardware supports them.
- [ ] Add coordinate helpers for chess notation such as `e4`.
- [ ] Build full FEN helpers for side to move, castling rights, en passant, and counters.
- [ ] Document the coordinate system used by FEN, LEDs, and piece status in more detail.
- [ ] Add tests for timeout, disconnection, out-of-order responses, and simultaneous requests.
- [ ] Add optional real-hardware integration tests behind a flag or separate scheme.
- [ ] Add packet logging or tracing for BLE diagnostics.
- [ ] Publish complete iOS and macOS example apps with Bluetooth permission setup.
- [ ] Keep tightening the CoreBluetooth isolation boundary as Apple concurrency annotations evolve.

## Acknowledgements

Thanks to [Chessnut](https://www.chessnutech.com) for building the electronic chessboards this package targets.

## License

EasyLinkSwiftSDK is available under the MIT License. See [LICENSE](LICENSE) for details.
