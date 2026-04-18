# Discovery and Connection

Show users the real Bluetooth devices announced by CoreBluetooth and connect to the selected peripheral.

## Overview

Use ``EasyLinkScanner/scan(profile:)`` to discover boards for a specific ``BoardProfile``. The stream yields ``EasyLinkDevice`` values containing the CoreBluetooth peripheral identifier, advertised name, and matched profile.

```swift
let scanTask = Task {
  for await device in EasyLinkScanner.scan(profile: .move) {
    print("Found", device.name, device.id)
  }
}
```

Cancel the task when scanning should stop:

```swift
scanTask.cancel()
```

## Connect to a Selected Device

Pass the selected device to ``EasyLinkClient/init(device:)``. This keeps the connection bound to the specific peripheral the user chose instead of connecting to the first board matching the profile.

```swift
let client = EasyLinkClient(device: selectedDevice)
try await client.connect()
```

If your app stores only the peripheral identifier, use ``EasyLinkClient/init(profile:deviceID:)``:

```swift
let client = EasyLinkClient(profile: .classic, deviceID: storedPeripheralID)
try await client.connect()
```

## Profile Matching

`BoardProfile.classic` matches advertised names that start with `Chessnut` except `Chessnut Move`. `BoardProfile.move` matches the exact name `Chessnut Move`.

## Bluetooth Permissions

Apps must include the platform Bluetooth usage descriptions required by CoreBluetooth. The SDK starts scanning, but the host app owns permission strings, UI lifecycle, and cancellation.
