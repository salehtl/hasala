// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ExtractBench",
  platforms: [.macOS(.v26)],
  dependencies: [.package(path: "../../HasalaCore")],
  targets: [
    .executableTarget(
      name: "ExtractBench",
      dependencies: [
        .product(name: "CoreNorm", package: "HasalaCore"),
        .product(name: "CoreTemplate", package: "HasalaCore"),
      ],
      path: "Sources/ExtractBench"
    )
  ],
  swiftLanguageModes: [.v5]
)
