// swift-tools-version: 6.2
//
// HasalaCore: the pure client core, ported from the TypeScript reference in
// reference/ledgerd-client and proven against conformance/ (spec 04 §2).
//
// EVERY module of the spec 04 §2.2 map is declared here, once, so the
// workstreams that fill them never edit this file concurrently. A module that is
// not implemented yet is a target holding a placeholder file. The layering is
// the target graph: a module may depend only on modules in a lower layer (or
// ones listed explicitly in §2.2). The compiler enforces only part of that:
// SwiftPM lets a target import any module its dependencies link, transitively
// (so a `Sync/` file could `import GRDB`). `imports.allow` and
// `ios/scripts/check-imports.sh` close that hole: each directory may import its
// declared dependencies and its §2.3 system modules, and nothing else.
//
// One name deviates from §2.2: its `CoreText` module (`Text/`) is `HasalaText`
// here. A package module called `CoreText` shadows Apple's CoreText framework,
// so the package does not build for iOS (GRDB's dependency scan resolves
// `CoreText` to this module) and a client that links both cannot reach
// `CTFont*`.
//
// Two third-party packages, pinned `exact:` (spec 04 §2.1; recorded in NOTICE):
// GRDB (MIT), linked by CoreStore and CoreProjection only (R6), and
// swift-collections (Apache-2.0) for OrderedCollections. Nothing else.
import PackageDescription

// MARK: - Layers (spec 04 §2.2)

let l0: [Target.Dependency] = [
  "CorePrimitives", "HasalaText", "CoreJSON", "CoreTime", "CoreMoney", "CoreResources",
]
let l1: [Target.Dependency] = ["CoreWire", "CoreCrypto", "CoreAuth", "CoreNorm", "CoreTemplate", "CoreMail"]
let l2: [Target.Dependency] = ["CoreReplay", "CoreInvariants", "CoreCategorize", "CoreDomain"]
let l3: [Target.Dependency] = ["CoreStore", "CoreProjection"]
let l4: [Target.Dependency] = ["CoreSync", "CoreOutbox", "CoreMailbox", "CoreSignals"]

let ordered: Target.Dependency = .product(name: "OrderedCollections", package: "swift-collections")
let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

/// One target per module; its sources live in `Sources/HasalaCore/<dir>`.
func core(
  _ name: String, _ dir: String, _ deps: [Target.Dependency] = [],
  resources: [Resource]? = nil
) -> Target {
  .target(name: name, dependencies: deps, path: "Sources/HasalaCore/\(dir)", resources: resources)
}

/// Every library module, in layer order. Each is a product of the same name, and
/// each but the resource-only CoreResources and CoreTestSupport has a
/// `<Module>Tests` unit-test target in `Tests/<Module>Tests`.
let libraries = [
  "CorePrimitives", "HasalaText", "CoreJSON", "CoreTime", "CoreMoney", "CoreResources",
  "CoreWire", "CoreCrypto", "CoreAuth", "CoreNorm", "CoreTemplate", "CoreMail",
  "CoreReplay", "CoreInvariants", "CoreCategorize", "CoreDomain",
  "CoreStore", "CoreProjection",
  "CoreSync", "CoreOutbox", "CoreMailbox", "CoreSignals",
  "HasalaModel", "HasalaKeychain", "CoreTestSupport", "CoreSoftAuth",
]
let unitTested = libraries.filter { $0 != "CoreResources" && $0 != "CoreTestSupport" }

let package = Package(
  name: "HasalaCore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: libraries.map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),  // MIT
    .package(url: "https://github.com/apple/swift-collections", exact: "1.7.2"),  // Apache-2.0
  ],
  targets: [
    // L0: no dependencies outside L0 (WS-7, apart from CoreResources' content).
    core("CorePrimitives", "Primitives"),
    core("HasalaText", "Text"),  // §2.2 `CoreText`, renamed: see the header
    core("CoreJSON", "JSON", ["HasalaText"]),
    core("CoreTime", "Time"),
    core("CoreMoney", "Money", ["HasalaText"]),
    // Resource-only. The single-file resources are added by their owners, one
    // line each, when the file lands (SwiftPM refuses a missing resource):
    //   .copy("merchant-dictionary.json")   WS-16 (03c §8.5), landed
    //   .copy("common-passwords-v1.txt")    WS-14 (04 §6.1.2)
    core("CoreResources", "Resources", resources: [.copy("templates"), .copy("sample"), .copy("merchant-dictionary.json")]),

    // L1
    core("CoreWire", "Wire", l0),
    core("CoreCrypto", "Crypto", l0 + ["CoreWire"]),
    core("CoreAuth", "Auth", l0),  // §2.2: L0, CoreJSON (in L0)
    core("CoreNorm", "Norm", l0),
    // §2.3: ICU's C API (uregex_*) through a module map over libicucore.
    core("CoreTemplate", "Template", l0 + ["HasalaICU"]),
    core("CoreMail", "Mail", l0),

    // L2
    core("CoreReplay", "Replay", l0 + ["CoreWire", ordered]),
    core("CoreInvariants", "Invariants", ["CoreReplay", "CoreWire", "CoreCrypto"]),
    core("CoreCategorize", "Categorize", l0 + [ordered]),  // §2.2: L0, CoreResources (in L0)
    core("CoreDomain", "Domain", l0 + ["CoreWire", "CoreReplay", "CoreCategorize", ordered]),

    // L3: the only GRDB users (R6).
    core("CoreStore", "Store", l0 + l1 + l2 + [grdb, ordered]),
    // L0 and CoreWire too (lower layers): the projector computes local dates
    // (CoreTime), writes gates JSON (CoreJSON) and folds the pending overlay (CoreWire ops).
    core("CoreProjection", "Projection", l0 + ["CoreWire", "CoreReplay", "CoreDomain", "CoreCategorize", grdb, ordered]),

    // L4
    core("CoreSync", "Sync", l0 + l1 + l2 + l3),
    core("CoreOutbox", "Outbox", ["CoreSync"]),
    // §2.2: L0-L3, CoreNorm, CoreTemplate, CoreMail (in L1), CoreOutbox, CoreSync.
    core("CoreMailbox", "Mailbox", l0 + l1 + l2 + l3 + ["CoreOutbox", "CoreSync"]),
    core("CoreSignals", "Signals", ["CoreDomain", "CoreProjection", ordered]),

    // A: the only FoundationModels importer; nothing in L0-L4 depends on it.
    core("HasalaModel", "Model", ["CoreCategorize"]),
    // A: the data-protection Keychain behind CoreStore's SecretStore (spec 04
    // §4.4). An adapter like HasalaModel: it needs Security, which §2.3 keeps
    // out of L0-L4, and lives here so its query logic runs under `swift test`.
    // Linked by the app only (its Platform layer); nothing in L0-L4 depends on it.
    core("HasalaKeychain", "Keychain", ["CorePrimitives", "CoreStore"]),

    // The system-library module CoreTemplate reaches ICU through (Sources/HasalaICU: a module
    // map and the declarations of the few uregex_* functions used; no code).
    .systemLibrary(name: "HasalaICU", path: "Sources/HasalaICU"),

    // T: test support, never linked by the app target.
    core("CoreTestSupport", "TestSupport", l0 + l1 + l2 + l3 + l4),
    core("CoreSoftAuth", "SoftAuth", ["CorePrimitives", "CoreAuth"]),

    .testTarget(
      name: "HasalaCoreConformanceTests",
      dependencies: l0 + l1 + l2 + l3 + l4 + ["HasalaModel", "CoreTestSupport", "CoreSoftAuth"],
      path: "Tests/HasalaCoreConformanceTests"),
    .testTarget(
      name: "HasalaCoreE2ETests",
      dependencies: [
        "CoreSync", "CoreAuth", "CoreSoftAuth", "CoreTestSupport", "CoreDomain", "CoreReplay", "CoreInvariants",
        "CoreCategorize", "CoreProjection", "CoreOutbox", "CoreMailbox", "CoreTemplate",
      ],
      path: "Tests/HasalaCoreE2ETests"),
  ]
    + unitTested.map { name in
      .testTarget(
        name: "\(name)Tests", dependencies: [.byName(name: name), "CoreTestSupport"],
        path: "Tests/\(name)Tests")
    },
  swiftLanguageModes: [.v6]
)
