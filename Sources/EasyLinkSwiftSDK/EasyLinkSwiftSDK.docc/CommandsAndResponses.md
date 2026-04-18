# Commands and Responses

Send board commands through the high-level client API.

## Overview

``EasyLinkClient`` chooses the correct command encoding for the selected ``BoardProfile``.

### Battery

Use ``EasyLinkClient/batteryStatus(timeout:)`` to request battery state:

```swift
let status = try await client.batteryStatus(timeout: .seconds(5))
print(status.percentage)
```

### LEDs

Create an ``LEDBoard`` and call ``EasyLinkClient/setLEDs(_:)``:

```swift
var leds = LEDBoard.allOff
leds[rankIndex: 6, fileIndex: 4] = .red
leds[rankIndex: 7, fileIndex: 4] = .blue

try await client.setLEDs(leds)
```

Classic boards treat every non-``LEDColor/off`` color as an enabled monochrome LED. Chessnut Move boards preserve the supported color value.

### Chessnut Move Commands

Chessnut Move supports auto-move and piece status:

```swift
try await client.setAutoMove(
  fen: "8/8/8/3k4/4K3/8/8/8",
  force: true
)

try await client.stopAutoMove()

let pieces = try await client.pieceStatus()
```

Calling Move-only commands with ``BoardProfile/classic`` throws ``EasyLinkError/unsupportedCommand(_:)``.
