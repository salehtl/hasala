// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OutlookTrustCheck",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "outlook-trust-check", targets: ["outlook-trust-check"])
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(
      name: "OutlookTrustCheckKit",
      dependencies: [.product(name: "CoreMail", package: "HasalaCore")],
      path: "Sources/OutlookTrustCheckKit"),
    .executableTarget(
      name: "outlook-trust-check",
      dependencies: ["OutlookTrustCheckKit"],
      path: "Sources/outlook-trust-check"),
    .testTarget(
      name: "OutlookTrustCheckTests",
      dependencies: ["OutlookTrustCheckKit", .product(name: "CoreMail", package: "HasalaCore")],
      path: "Tests/OutlookTrustCheckTests"),
  ],
  swiftLanguageModes: [.v6]
)
