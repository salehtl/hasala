// Locating and reading the shared fixtures (spec 04 §19.1 T1).
//
// `conformance/` is read IN PLACE from the repository, never copied into the
// package or a bundle (spec 04 §1.5: no product may contain a conformance file).
// The root is found by walking up from this file, or named by
// HASALA_CONFORMANCE_DIR. The private real-mail fixtures are read only through
// HASALA_PRIVATE_FIXTURES (a checkout of the private fixtures repository, laid
// out under the same paths); tests that need them are disabled by name when it
// is unset, and never print fixture content when they fail.
import CoreJSON
import CorePrimitives
import Foundation

enum Fixtures {
  /// The repository's `conformance/` directory.
  static let conformanceRoot: URL = {
    if let dir = ProcessInfo.processInfo.environment["HASALA_CONFORMANCE_DIR"], !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      let candidate = dir.appendingPathComponent("conformance", isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("op/manifest.json").path) {
        return candidate
      }
      dir.deleteLastPathComponent()
    }
    fatalError("conformance/ not found above \(#filePath); set HASALA_CONFORMANCE_DIR")
  }()

  /// `<HASALA_PRIVATE_FIXTURES>/conformance`, or nil when the variable is unset.
  static let privateConformanceRoot: URL? = {
    guard let dir = ProcessInfo.processInfo.environment["HASALA_PRIVATE_FIXTURES"], !dir.isEmpty else { return nil }
    return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("conformance", isDirectory: true)
  }()

  static var hasPrivate: Bool { privateConformanceRoot != nil }

  static func data(_ relative: String) throws -> Data {
    try Data(contentsOf: conformanceRoot.appendingPathComponent(relative))
  }

  /// A fixture parsed by CoreJSON (the parser under test elsewhere; here it is
  /// only the reader, and the corpus test cross-checks it).
  static func json(_ relative: String) throws -> JSONValue {
    try JSONParser.parse(Array(try data(relative)))
  }

  /// Every `*.json` file under `root`, as paths relative to it, sorted.
  static func jsonFiles(under root: URL) -> [String] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var out: [String] = []
    for case let url as URL in e where url.pathExtension == "json" {
      out.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
    }
    return out.sorted()
  }
}

// MARK: - Manifest field access

enum FixtureError: Error, CustomStringConvertible {
  case missing(String)
  var description: String {
    switch self {
    case .missing(let f): "fixture field missing or mistyped: \(f)"
    }
  }
}

extension JSONValue {
  func string(_ key: String) throws -> String {
    guard let s = self[key]?.stringValue else { throw FixtureError.missing(key) }
    return s
  }

  func int(_ key: String) throws -> Int {
    guard let n = self[key]?.numberValue?.int64Value else { throw FixtureError.missing(key) }
    return Int(n)
  }

  func array(_ key: String) throws -> [JSONValue] {
    guard let a = self[key]?.arrayValue else { throw FixtureError.missing(key) }
    return a
  }

  func base64(_ key: String) throws -> Data { try Base64.decode(try string(key)) }
}

// MARK: - Blob frame v1 (fixtures only)

/// The v1 frame layout, read-only and test-only: enough to reach the gzip
/// payload of conformance/blob and conformance/ts. The product reader is
/// CoreWire's (WS-9); this exists so the WS-7 primitives can be checked against
/// those bytes now.
///
/// `[1 version][2 BE aad length][aad][12 nonce][4 BE payload length ‖ gzip ‖
/// zero pad][16 tag]`, the whole frame being one size bucket.
struct FrameV1 {
  let version: UInt8
  let aad: Data
  let nonce: Data
  let gzip: Data
  let tag: Data
  /// Bytes before the padding, the 16-byte tag included (the manifests'
  /// `expect_pre_pad_length`).
  let prePadLength: Int

  init(_ b: Data) throws {
    let b = [UInt8](b)
    func be(_ at: Int, _ n: Int) throws -> Int {
      guard at + n <= b.count else { throw FixtureError.missing("frame truncated at \(at)") }
      return b[at..<(at + n)].reduce(0) { $0 << 8 | Int($1) }
    }
    version = b[0]
    let aadLength = try be(1, 2)
    aad = Data(b[3..<(3 + aadLength)])
    nonce = Data(b[(3 + aadLength)..<(15 + aadLength)])
    let payloadAt = 15 + aadLength
    let payloadLength = try be(payloadAt, 4)
    gzip = Data(b[(payloadAt + 4)..<(payloadAt + 4 + payloadLength)])
    tag = Data(b[(b.count - 16)...])
    prePadLength = payloadAt + 4 + payloadLength + 16
  }
}
