# EasyLinkSwiftSDK

Native Swift SDK for Chessnut electronic chess boards.

The package targets iOS 16 and macOS 13, and communicates over Bluetooth Low Energy with CoreBluetooth. It does not vendor or wrap the C/C++ EasyLinkSDK.

## Supported Profiles

- `BoardProfile.classic`: Chessnut Air, Air+, Go, Pro style BLE profile.
- `BoardProfile.move`: Chessnut Move BLE profile.

Both profiles use:

- FEN service: `1b7e8261-2877-41c3-b46e-cf057c562023`
- FEN notification characteristic: `1b7e8262-2877-41c3-b46e-cf057c562023`
- Operation service: `1b7e8271-2877-41c3-b46e-cf057c562023`
- Command characteristic: `1b7e8272-2877-41c3-b46e-cf057c562023`
- Response characteristic: `1b7e8273-2877-41c3-b46e-cf057c562023`

## Example

```swift
import EasyLinkSwiftSDK

let client = EasyLinkClient(profile: .move)

try await client.connect()
try await client.enableRealtimeUpdates()

Task {
  for await fen in client.fenUpdates {
    print("Board:", fen)
  }
}

let battery = try await client.batteryStatus()
print("Battery:", battery.percentage)
```

## Commands

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

FEN notifications are decoded using the same nibble mapping as the C++ SDK's `ChessLink::toFen`: board payload bytes `[2]...[33]`, two squares per byte, and the piece table `["", "q", "k", "b", "p", "n", "R", "P", "r", "B", "N", "Q", "K"]`.

The public FEN string is the placement field only, matching the original SDK behavior.
