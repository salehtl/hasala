// The disposition over the operator's real bank mail, read only from HASALA_PRIVATE_FIXTURES
// (the private normalizer fixtures, the same raw messages the conformance suite reads). Disabled
// by name without it. Never prints or records content: only counts and fixture names.
import CoreJSON
import CoreMail
import CoreMailbox
import CorePrimitives
import CoreTemplate
import Foundation
import Testing

private let privateRoot: URL? = {
  guard let dir = ProcessInfo.processInfo.environment["HASALA_PRIVATE_FIXTURES"], !dir.isEmpty else { return nil }
  return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("conformance/normalizer", isDirectory: true)
}()

@Suite(.enabled(if: privateRoot != nil, "needs HASALA_PRIVATE_FIXTURES"))
struct PrivateCorpusDispositionTests {
  @Test func realBankMailIsNeverSetAsideAndDirectAlertsParse() throws {
    let root = try #require(privateRoot)
    let templates = BundledTemplates.load().templates
    let banks = ["dib.ae", "emiratesnbd.com"]
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
      ($0.hasPrefix("dib-") || $0.hasPrefix("enbd-")) && $0.hasSuffix(".json")
    }.sorted()
    #expect(!files.isEmpty)
    var unparsed: [String] = []
    var parsed = 0
    for f in files {
      let v = try JSONParser.parse([UInt8](try Data(contentsOf: root.appendingPathComponent(f))))
      guard let rawB64 = v["raw_base64"]?.stringValue, let received = v["received_at"]?.stringValue else { continue }
      let raw = [UInt8](try Base64.decode(rawB64))
      let ms = try parseInstantMsForTest(received)
      let from = MailHeadersForTest.from(raw)
      let r = MessageDisposer.parse(
        raw: raw, messageID: f, internalDateMs: ms, topLevelFrom: from, templates: templates, bankDomains: banks,
        trusted: banks, provider: .gmail, linkedAddress: nil, spam: false, analyze: AuthResults.analyze)
      let fromBank = BankDomains.isMember(BankDomains.domainOf(from), of: banks)
      switch r {
      case .setAside:
        // Only mail that is not from a bank may be set aside (a Google notice is in the set).
        #expect(!fromBank, "\(f): bank mail set aside")
      case .mail(let m):
        #expect(fromBank, "\(f): non-bank mail kept")
        if m.fields == nil { unparsed.append(f) } else { parsed += 1 }
        // Most of this corpus reached ledgerd by SMTP, not Gmail (no mx.google.com verdict);
        // without a passing verdict the sender is never treated as verified.
        if m.gates.ar != "pass" { #expect(!m.gates.senderTrusted, "\(f)") }
      }
    }
    // Templates read the transaction alerts; the service notices ("Dear customer") stay the
    // empty review shape. Content-free: names only.
    #expect(parsed >= 10, "parsed \(parsed); unparsed: \(unparsed)")
  }
}

import CoreTime

@Suite(.enabled(if: privateRoot != nil, "needs HASALA_PRIVATE_FIXTURES"))
struct PrivateGmailDeliveredTests {
  /// Real bank alerts as Gmail delivered them (topmost mx.google.com Authentication-Results).
  @Test func gmailDeliveredBankMailIsReadAndJudgedByTheVerdict() throws {
    let root = try #require(privateRoot).deletingLastPathComponent().deletingLastPathComponent()
    var files: [URL] = []
    for dir in ["server/internal/origin/testdata", "conformance/templates/eml"] {
      let base = root.appendingPathComponent(dir, isDirectory: true)
      guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
      for case let url as URL in walk where url.pathExtension == "eml" { files.append(url) }
    }
    let gmailDelivered = files.sorted { $0.path < $1.path }.filter { url in
      guard let data = try? Data(contentsOf: url) else { return false }
      let ar = MailHeaders.headerBlock(rawMessage: [UInt8](data)).split(whereSeparator: \.isNewline)
        .first { $0.lowercased().hasPrefix("authentication-results:") }
      return ar.map { $0.dropFirst("authentication-results:".count).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("mx.google.com;") } ?? false
    }
    #expect(gmailDelivered.count >= 5, "\(gmailDelivered.count) Gmail-delivered .eml files")
    let templates = BundledTemplates.load().templates
    let banks = ["adib.ae", "dib.ae", "emiratesnbd.com"]
    for url in gmailDelivered {
      let f = url.lastPathComponent
      let raw = [UInt8](try Data(contentsOf: url))
      let r = MessageDisposer.parse(
        raw: raw, messageID: f, internalDateMs: 1_750_000_000_000, topLevelFrom: MailHeadersForTest.from(raw),
        templates: templates, bankDomains: banks, trusted: banks, provider: .gmail, linkedAddress: nil, spam: false, analyze: AuthResults.analyze)
      guard case .mail(let m) = r else {
        Issue.record("\(f): set aside")
        continue
      }
      #expect(m.gates.ar == "pass" && m.gates.senderTrusted, "\(f): \(m.gates.ar)")
      let d = MessageDisposer.finalize(m, provider: .gmail, grantID: "g", cards: [:], categorizer: NoCategorizer())
      #expect(d.needsReview, "\(f)")
    }
  }
}

/// Real alerts as Outlook.com delivered them (`outlook-*.eml`, exported with Graph `$value`, WP0
/// check C6), when the private repository has them. Skipped by name until it does.
private let outlookDelivered: [URL] = {
  guard let root = privateRoot?.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("conformance/outlook", isDirectory: true),
    let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
  else { return [] }
  return names.filter { $0.hasPrefix("outlook-") && $0.hasSuffix(".eml") }.sorted().map {
    root.appendingPathComponent($0)
  }
}()

@Suite(.enabled(if: !outlookDelivered.isEmpty, "needs HASALA_PRIVATE_FIXTURES with conformance/outlook/outlook-*.eml"))
struct PrivateOutlookDeliveredTests {
  /// Bank mail is never set aside under the Outlook rule, and while the trust gate is closed
  /// nothing files without review, whatever the rule says.
  @Test func outlookDeliveredBankMailIsReadAndWaitsForReview() throws {
    let templates = BundledTemplates.load().templates
    let banks = ["dib.ae", "emiratesnbd.com"]
    let gate = OutlookProvider(
      oauth: MicrosoftOAuthClient(config: MicrosoftOAuthConfig(clientID: "unset", redirectScheme: "unset"), http: NoHTTP()),
      http: NoHTTP(), link: MemoryOutlookLinkStore(), clock: FixedClockForTest())
    for url in outlookDelivered {
      let f = url.lastPathComponent
      let raw = [UInt8](try Data(contentsOf: url))
      let r = MessageDisposer.parse(
        raw: raw, messageID: f, internalDateMs: 1_750_000_000_000, topLevelFrom: MailHeadersForTest.from(raw),
        templates: templates, bankDomains: banks, trusted: banks, provider: .outlook, linkedAddress: nil, spam: false, analyze: gate.analyzeAuthResults)
      guard case .mail(let m) = r else {
        Issue.record("\(f): set aside")
        continue
      }
      let d = MessageDisposer.finalize(m, provider: .outlook, grantID: "g", cards: [:], categorizer: NoCategorizer())
      #expect(d.needsReview, "\(f)")
    }
  }
}

private struct NoHTTP: HTTPExchange {
  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse { throw .offline }
}

private struct FixedClockForTest: Clock {
  func nowMs() -> Int64 { 1_750_000_000_000 }
}

private func parseInstantMsForTest(_ s: String) throws -> Int64 { try parseInstantMs(s) }

private enum MailHeadersForTest {
  /// The top-level From header value.
  static func from(_ raw: [UInt8]) -> String {
    let text = String(decoding: raw.prefix(64 * 1024), as: UTF8.self)
    for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if line.isEmpty { break }
      if line.lowercased().hasPrefix("from:") { return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    }
    return ""
  }
}
