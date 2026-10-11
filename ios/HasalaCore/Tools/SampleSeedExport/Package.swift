// swift-tools-version: 6.2
//
// SampleSeedExport: the generator of HasalaCore's bundled sample seed
// (Sources/HasalaCore/Resources/sample/maya-v1.json and SampleManifest.swift),
// built from HasalaMocks' MayaLedger so the sample a reviewer loads is the
// ledger the Debug screens and the Paper boards show.
//
//   swift test --package-path ios/HasalaCore/Tools/SampleSeedExport
//       check: the committed seed and manifest equal the generator's output
//   HASALA_WRITE_SAMPLE=1 swift test --package-path ios/HasalaCore/Tools/SampleSeedExport
//       write them
//
// A separate package because HasalaCore must not depend on HasalaKit (the
// mocks are Debug-only app code). HASALA_KIT_PATH points the generator at
// another HasalaKit checkout (default: this repository's ios/HasalaKit).
import Foundation
import PackageDescription

let kit = ProcessInfo.processInfo.environment["HASALA_KIT_PATH"] ?? "../../../HasalaKit"

let package = Package(
  name: "SampleSeedExport",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../.."),
    .package(path: kit),
  ],
  targets: [
    .testTarget(
      name: "SampleSeedExportTests",
      dependencies: [
        .product(name: "CoreDomain", package: "HasalaCore"),
        .product(name: "CoreCategorize", package: "HasalaCore"),
        .product(name: "CoreJSON", package: "HasalaCore"),
        .product(name: "CorePrimitives", package: "HasalaCore"),
        .product(name: "CoreResources", package: "HasalaCore"),
        .product(name: "CoreTime", package: "HasalaCore"),
        .product(name: "CoreWire", package: "HasalaCore"),
        .product(name: "HasalaModels", package: "HasalaKit"),
        .product(name: "HasalaMocks", package: "HasalaKit"),
      ],
      path: "Tests/SampleSeedExportTests"),
  ],
  swiftLanguageModes: [.v6]
)
