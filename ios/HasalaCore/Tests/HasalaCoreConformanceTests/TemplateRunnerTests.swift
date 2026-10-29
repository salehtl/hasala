import CoreJSON
import CoreResources
import Foundation
import Testing

@testable import CoreTemplate

enum TemplateRunnerProbe {
  static let file = "synthetic-dib-sms-purchase.json"
  static let id = "dib.sms.purchase.v1"
  static var corpusFile: String { "corpus-\(id).json" }

  static func source() throws -> Data {
    try Data(contentsOf: TemplateFixtures.publicDir.appendingPathComponent(TemplateFixtures.smsSubdir).appendingPathComponent(file))
  }

  static func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("template-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func write(_ data: Data, _ root: URL, _ name: String, sub: String = TemplateFixtures.smsSubdir) throws {
    let dir = sub.isEmpty ? root : root.appendingPathComponent(sub)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try data.write(to: dir.appendingPathComponent(name))
  }

  static func edit(_ field: String, _ v: Any?) -> Any {
    switch field {
    case "matched": return false
    case "error": return "no_match"
    case "amount_minor": return ((v as? String) ?? "") + "0"
    case "currency": return "USD"
    case "direction": return "credit"
    case "posted_at": return ""
    case "merchant": return ((v as? String) ?? "") + "X"
    case "last4": return "9999"
    case "is_transfer": return !((v as? Bool) ?? false)
    default: return ((v as? [String]) ?? []) + ["merchant"]
    }
  }

  static func edited(_ field: String) throws -> (data: Data, caseName: String) {
    var doc = try #require(try JSONSerialization.jsonObject(with: try source()) as? [String: Any])
    var cases = try #require(doc["cases"] as? [[String: Any]])
    var expect = try #require(cases[0]["expect"] as? [String: Any])
    #expect(expect["matched"] as? Bool == true)
    expect[field] = edit(field, expect[field])
    cases[0]["expect"] = expect
    doc["cases"] = cases
    return (try JSONSerialization.data(withJSONObject: doc), try #require(cases[0]["name"] as? String))
  }

  static func bundledBytes(_ id: String) throws -> Data {
    let url = try #require(CoreResources.bundle.url(forResource: "\(id).json", withExtension: nil, subdirectory: "templates"))
    return try Data(contentsOf: url)
  }
}

@Suite("the template runners")
struct TemplateRunnerTests {
  static let fields = [
    "matched", "error", "amount_minor", "currency", "direction", "posted_at", "merchant", "last4", "is_transfer", "empty_groups",
  ]

  @Test("the runner reads templates/sms, public and private, and the committed text cases pass")
  func readsTheTextDirectory() throws {
    let root = try TemplateRunnerProbe.root()
    defer { try? FileManager.default.removeItem(at: root) }
    try TemplateRunnerProbe.write(try TemplateRunnerProbe.source(), root, TemplateRunnerProbe.file)
    try TemplateRunnerProbe.write(try TemplateRunnerProbe.source(), root, TemplateRunnerProbe.corpusFile)
    let synthetic = TemplateFixtures.files(root, prefix: "synthetic-")
    let corpus = TemplateFixtures.files(root, prefix: "corpus-")
    #expect(synthetic.map(\.file) == ["\(TemplateFixtures.smsSubdir)/\(TemplateRunnerProbe.file)"])
    #expect(corpus.map(\.file) == ["\(TemplateFixtures.smsSubdir)/\(TemplateRunnerProbe.corpusFile)"])
    for f in synthetic + corpus {
      let (n, m, failures) = try TemplateFixtures.run(f)
      #expect(n > 0 && m > 0, "\(f.file)")
      #expect(failures.isEmpty, "\(f.file): \(failures.joined(separator: "; "))")
    }
  }

  @Test("a text case whose expectation was changed by hand makes the runner fail", arguments: fields)
  func failsOnAHandEditedTextCase(_ field: String) throws {
    let (data, caseName) = try TemplateRunnerProbe.edited(field)
    for (prefix, name) in [("synthetic-", TemplateRunnerProbe.file), ("corpus-", TemplateRunnerProbe.corpusFile)] {
      let root = try TemplateRunnerProbe.root()
      defer { try? FileManager.default.removeItem(at: root) }
      try TemplateRunnerProbe.write(data, root, name)
      let files = TemplateFixtures.files(root, prefix: prefix)
      #expect(files.map(\.file) == ["\(TemplateFixtures.smsSubdir)/\(name)"])
      let (_, _, failures) = try TemplateFixtures.run(try #require(files.first))
      #expect(failures == ["\(caseName): \(field)"], "\(prefix)\(field)")
    }
  }

  @Test("the corpus check fails when a text template has no corpus file in templates/sms")
  func coverageNeedsEveryTextCorpus() throws {
    let bundled = (BundledTemplates.load(channel: .mail).templates + BundledTemplates.load(channel: .sms).templates).map(\.definition)
    let root = try TemplateRunnerProbe.root()
    defer { try? FileManager.default.removeItem(at: root) }
    for d in bundled where !TemplateFixtures.corpusPending.contains(d.id) {
      let doc = Data("{\"kind\":\"corpus\",\"definition\":".utf8) + (try TemplateRunnerProbe.bundledBytes(d.id)) + Data(",\"cases\":[]}".utf8)
      try TemplateRunnerProbe.write(doc, root, "corpus-\(d.id).json", sub: d.isSMS ? TemplateFixtures.smsSubdir : "")
    }
    let all = TemplateFixtures.files(root, prefix: "corpus-")
    #expect(all.count == bundled.count - TemplateFixtures.corpusPending.count)
    #expect(try TemplateFixtures.uncovered(all, bundled: bundled).isEmpty)

    let debit = "dib.sms.debit.v1"
    let lessDebit = all.filter { $0.file != "\(TemplateFixtures.smsSubdir)/corpus-\(debit).json" }
    #expect(lessDebit.count == all.count - 1)
    #expect(try TemplateFixtures.uncovered(lessDebit, bundled: bundled).contains { $0.hasPrefix("no corpus fixture for \(debit) ") })

    try FileManager.default.moveItem(
      at: root.appendingPathComponent(TemplateFixtures.smsSubdir).appendingPathComponent("corpus-\(debit).json"),
      to: root.appendingPathComponent("corpus-\(debit).json"))
    let misplaced = try TemplateFixtures.uncovered(TemplateFixtures.files(root, prefix: "corpus-"), bundled: bundled)
    #expect(misplaced.contains { $0.hasPrefix("corpus-\(debit).json holds \(debit)") })
    #expect(misplaced.contains { $0.hasPrefix("no corpus fixture for \(debit) ") })
  }

  @Test(
    "[real-corpus] the corpus check fails on the private fixtures less one text corpus file",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func coverageOnThePrivateFixtures() throws {
    let bundled = (BundledTemplates.load(channel: .mail).templates + BundledTemplates.load(channel: .sms).templates).map(\.definition)
    let files = TemplateFixtures.corpus()
    #expect(try TemplateFixtures.uncovered(files, bundled: bundled).isEmpty)
    let debit = "dib.sms.debit.v1"
    let lessDebit = files.filter { $0.file != "\(TemplateFixtures.smsSubdir)/corpus-\(debit).json" }
    #expect(lessDebit.count == files.count - 1)
    #expect(try TemplateFixtures.uncovered(lessDebit, bundled: bundled).contains { $0.hasPrefix("no corpus fixture for \(debit) ") })
  }
}
