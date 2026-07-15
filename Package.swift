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
  targets: [
    .executableTarget(
      name: "CodexRadar",
      path: "Sources/CodexRadar",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "CodexRadarTests",
      dependencies: ["CodexRadar"]
    ),
  ]
)
