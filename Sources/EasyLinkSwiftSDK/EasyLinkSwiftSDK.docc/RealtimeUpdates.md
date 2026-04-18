# Realtime Updates

Receive board positions as FEN placement strings.

## Overview

After connecting, call ``EasyLinkClient/enableRealtimeUpdates()`` and consume ``EasyLinkClient/fenUpdates``.

```swift
let client = EasyLinkClient(device: selectedDevice)
try await client.connect()
try await client.enableRealtimeUpdates()

Task {
  for await placement in client.fenUpdates {
    print("Board position:", placement)
  }
}
```

The stream emits only the placement field of a FEN string, for example:

```text
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR
```

It does not include side to move, castling rights, en passant target, halfmove clock, or fullmove number.

## Cancellation

Call ``EasyLinkClient/disconnect()`` when the board session ends. Disconnecting cancels the internal notification task and finishes transport work.
