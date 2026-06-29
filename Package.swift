// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "tmterm",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "tmterm", targets: ["tmterm"])
  ],
  dependencies: [
    .package(url: "https://github.com/hogelog/SwiftTerm", branch: "fix-skip-zero-width-cells")
  ],
  targets: [
    .executableTarget(
      name: "tmterm",
      dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm")
      ]
    )
  ]
)
