import CoreExtract
import CoreJSON
import CoreMailbox
import CoreTime
import Foundation
import Testing

struct TextCase: Sendable {
  var name: String
  var sender: String?
  var text: String
  var receivedAtMs: Int64
  var windowOpen: Bool

  var arrival: BankTextArrival { BankTextArrival(text: text, sender: sender, receivedAtMs: receivedAtMs, testWindowOpen: windowOpen) }

  static let file = "sms-extract/synthetic-reading.json"

  static func all() throws -> [TextCase] {
    try (TextGolden.json(file)["cases"]?.arrayValue ?? []).map(TextCase.init)
  }

  static func named(_ name: String) throws -> TextCase {
    try #require(try all().first { $0.name == name }, "no case \(name)")
  }

  init(_ c: JSONValue) throws {
    name = c["name"]?.stringValue ?? ""
    sender = c["sender"]?.stringValue
    text = c["text"]?.stringValue ?? ""
    receivedAtMs = try parseInstantMs(c["received_at"]?.stringValue ?? "")
    windowOpen = c["test_window_open"]?.boolValue ?? false
  }

  init(name: String, sender: String?, text: String, receivedAtMs: Int64, windowOpen: Bool = false) {
    self.name = name
    self.sender = sender
    self.text = text
    self.receivedAtMs = receivedAtMs
    self.windowOpen = windowOpen
  }
}

enum ReadingJSON {
  static func text(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }

  static func of(_ r: BankTextReading) -> JSONValue {
    switch r {
    case .setUpTest:
      return jobj([("reading", .string("set_up_test"))])
    case .dropped(let k, let counted, let bank):
      return jobj([("reading", .string("dropped")), ("drop_kind", .string(k.rawValue)), ("counted", .bool(counted)), ("bank", text(bank))])
    case .kept(let k):
      var p: [(String, JSONValue)] = [
        ("reading", .string("kept")), ("sender_kind", .string(k.sender.rawValue)), ("bank", text(k.bank)), ("tier", .string(k.tier)),
        ("template", text(k.template?.ref)), ("sender_matches", .bool(k.template?.senderMatches ?? false)),
        ("transfer_role", text(k.template?.transferRole?.rawValue)), ("marked", .bool(k.marked)), ("held", .bool(k.held)),
        ("counts_as_payment", .bool(k.countsAsPayment)),
      ]
      if let f = k.fields {
        p += [
          ("amount_minor", .string(String(f.amountMinor))), ("currency", .string(f.currency)), ("direction", .string(f.direction)),
          ("merchant", .string(f.merchant)), ("last4", .string(f.last4)), ("posted_at", .string(f.postedAt)),
          ("posted_precision", .string(f.precision)), ("is_transfer", .bool(f.isTransfer)),
        ]
      } else {
        p += [
          ("merchant", .string(k.merchant)), ("last4", .string(k.last4)), ("posted_at", .string(k.postedAt)),
          ("posted_precision", .string(k.precision)),
        ]
      }
      return jobj(p)
    }
  }
}

@Suite("conformance/sms-extract")
struct SMSExtractGoldenTests {
  @Test("synthetic-reading.json is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)")
  func golden() throws {
    let file = try TextGolden.json(TextCase.file)
    #expect(file["schema_version"]?.numberValue?.int64Value == 1)
    var out: [JSONValue] = []
    var names: Set<String> = []
    for c in file["cases"]?.arrayValue ?? [] {
      let t = try TextCase(c)
      #expect(names.insert(t.name).inserted, "\(t.name) twice")
      let (reading, _) = BankTextReader.read(t.arrival)
      guard var o = c.objectValue else { continue }
      o["expect"] = ReadingJSON.of(reading)
      out.append(.object(o))
    }
    #expect(out.count >= 60)
    guard var doc = file.objectValue else { return }
    doc["cases"] = .array(out)
    try TextGolden.check(TextCase.file, .object(doc))
  }

  @Test("every file in conformance/sms-extract is synthetic or the README")
  func onlySynthetic() throws {
    let dir = TextGolden.conformanceRoot.appendingPathComponent("sms-extract")
    for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where !f.hasPrefix(".") {
      #expect(f.hasPrefix("synthetic-") || f == "README.md", "\(f)")
    }
  }
}
