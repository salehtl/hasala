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
        .product(name: "CoreExtract", package: "HasalaCore"),
        .product(name: "CoreNorm", package: "HasalaCore"),
        .product(name: "CoreTemplate", package: "HasalaCore"),
        .product(name: "CoreTime", package: "HasalaCore"),
      ],
      path: "Sources/ExtractBench"
    ),
    .testTarget(
      name: "ExtractBenchTests",
      dependencies: ["ExtractBench"],
      path: "Tests/ExtractBenchTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
