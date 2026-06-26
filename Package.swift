// swift-tools-version: 5.9

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
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.13.0")
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
