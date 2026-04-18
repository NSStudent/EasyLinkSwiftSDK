// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "EasyLinkSwiftSDK",
  platforms: [
    .iOS(.v16),
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "EasyLinkSwiftSDK",
      targets: ["EasyLinkSwiftSDK"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
  ],
  targets: [
    .target(name: "EasyLinkSwiftSDK"),
    .testTarget(
      name: "EasyLinkSwiftSDKTests",
      dependencies: ["EasyLinkSwiftSDK"]
    )
  ],
  swiftLanguageModes: [.v6]
)
