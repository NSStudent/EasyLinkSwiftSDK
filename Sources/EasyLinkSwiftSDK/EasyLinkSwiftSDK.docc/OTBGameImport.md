# OTB Game Import

Download games recorded by the board during over-the-board play.

## Overview

Use ``EasyLinkClient/importOTBGames(timeout:)`` to switch the board into upload mode, query the number of stored games, and collect each game as an ``OTBGame``.

```swift
let games = try await client.importOTBGames(timeout: .seconds(5))

for game in games {
  for position in game.positions {
    print(position)
  }
}
```

Each ``OTBGame/positions`` value is a FEN placement string captured from the board. The SDK returns only the placement field, matching ``EasyLinkClient/fenUpdates``.

## Realtime Updates

Upload mode stops realtime FEN notifications while the board sends stored games. Call ``EasyLinkClient/enableRealtimeUpdates()`` after importing if your UI should resume live board updates.

```swift
let games = try await client.importOTBGames()
try await client.enableRealtimeUpdates()
```

## Empty Storage

When the board reports that no OTB games are stored, the method returns an empty array.

```swift
let games = try await client.importOTBGames()

if games.isEmpty {
  print("No stored games")
}
```

## Timeout And Disconnects

The timeout applies while waiting for upload responses and FEN packets. If the board disconnects during import, the method throws ``EasyLinkError/disconnected``.

## Topics

### Importing

- ``EasyLinkClient/importOTBGames(timeout:)``
- ``OTBGame``
