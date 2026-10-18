// swift-tools-version: 6.2
// HasalaKit: the UI-side modules of the Hasala app (spec 04 §2.5).
//
// - HasalaModels: UI read models (value types) and money formatting.
// - HasalaDesign: tokens (generated from Paper), typography, fonts, components.
// - HasalaMocks:  the Maya scenario that drives Debug builds, previews and UI tests.
//
// It does not depend on HasalaCore yet; when HasalaCore lands, HasalaModels
// takes CoreMoney/CoreTime from it (spec 04 §2.5) instead of its own Money.

import PackageDescription

let package = Package(
  name: "HasalaKit",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "HasalaModels", targets: ["HasalaModels"]),
    .library(name: "HasalaDesign", targets: ["HasalaDesign"]),
    .library(name: "HasalaMocks", targets: ["HasalaMocks"]),
    .library(name: "HasalaWidgetData", targets: ["HasalaWidgetData"]),
  ],
  targets: [
    .target(name: "HasalaModels"),
    .target(
      name: "HasalaDesign",
      dependencies: ["HasalaModels"],
      resources: [.copy("Fonts")]
    ),
    .target(name: "HasalaMocks", dependencies: ["HasalaModels"]),
    .target(name: "HasalaWidgetData", dependencies: ["HasalaModels"]),
    .testTarget(
      name: "HasalaKitTests", dependencies: ["HasalaModels", "HasalaDesign", "HasalaMocks", "HasalaWidgetData"]),
  ]
)
