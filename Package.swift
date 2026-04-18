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
  targets: [
    .target(name: "EasyLinkSwiftSDK"),
    .testTarget(
      name: "EasyLinkSwiftSDKTests",
      dependencies: ["EasyLinkSwiftSDK"]
    )
  ]
)
