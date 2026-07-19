// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexRadar",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CodexRadar", targets: ["CodexRadar"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
  ],
  targets: [
    .executableTarget(
      name: "CodexRadar",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Sources/CodexRadar",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "CodexRadarTests",
      dependencies: ["CodexRadar"]
    ),
  ]
)
