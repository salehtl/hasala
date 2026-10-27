import CoreExtract
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation
import Testing

private let privateTexts: URL? = {
  guard let dir = ProcessInfo.processInfo.environment["HASALA_PRIVATE_FIXTURES"], !dir.isEmpty else { return nil }
  return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("conformance/templates/sms", isDirectory: true)
}()

@Suite(.enabled(if: privateTexts != nil, "needs HASALA_PRIVATE_FIXTURES"))
struct PrivateTextCorpusTests {
  struct Text {
    var family: String
    var sender: String
    var text: String
    var receivedAtMs: Int64
    var readBy: String
    var expect: JSONValue
  }

  static func texts() throws -> [Text] {
    let root = try #require(privateTexts)
    var out: [Text] = []
    for f in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where f.hasSuffix(".json") {
      let doc = try JSONParser.parse([UInt8](try Data(contentsOf: root.appendingPathComponent(f))))
      let family = doc["family"]?.stringValue ?? ""
      for c in doc["cases"]?.arrayValue ?? [] {
        let text = String(decoding: try Base64.decode(c["text_base64"]?.stringValue ?? ""), as: UTF8.self)
        out.append(
          Text(
            family: family, sender: c["sender"]?.stringValue ?? "", text: text,
            receivedAtMs: try parseInstantMs(c["received_at"]?.stringValue ?? ""), readBy: c["read_by"]?.stringValue ?? "",
            expect: c["expect"] ?? .null))
      }
    }
    return out
  }

  @Test("[real-corpus] every DIB text a DIB SMS template reads is kept with its fields, and no payment text is dropped")
  func corpus() throws {
    let texts = try Self.texts()
    #expect(texts.count > 4000)
    var drops: [String: Int] = [:]
    var otherKept = 0
    var otherDropped = 0
    var paymentKept = 0
    var paymentReview = 0
    var templateKept = 0
    var failures: [String] = []
    for (i, t) in texts.enumerated() {
      let isPayment = t.family != "other"
      for sender in [t.sender, nil, "+971500000000"] as [String?] {
        let (reading, _) = BankTextReader.read(BankTextArrival(text: t.text, sender: sender, receivedAtMs: t.receivedAtMs))
        switch reading {
        case .setUpTest:
          failures.append("#\(i): set-up test")
        case .dropped(let k, let counted, _):
          if isPayment {
            failures.append("#\(i) \(t.family): payment text dropped as \(k.rawValue) (sender \(sender == nil ? "none" : "given"))")
          } else if sender == t.sender {
            drops[k.rawValue, default: 0] += 1
            otherDropped += 1
            #expect(counted)
          }
        case .kept(let k):
          if !isPayment {
            if sender == t.sender { otherKept += 1 }
            continue
          }
          if sender == t.sender {
            paymentKept += 1
            if k.template == nil { paymentReview += 1 }
          }
          guard !t.readBy.isEmpty else { continue }
          guard let hit = k.template, let f = k.fields else {
            failures.append("#\(i) \(t.family): a template read it, but the reading has no template hit")
            continue
          }
          if sender == t.sender { templateKept += 1 }
          if hit.id != t.readBy { failures.append("#\(i): read by another template") }
          if hit.senderMatches != (sender == t.sender) { failures.append("#\(i): sender match") }
          let x = t.expect
          if String(f.amountMinor) != x["amount_minor"]?.stringValue { failures.append("#\(i): amount") }
          if f.direction != x["direction"]?.stringValue { failures.append("#\(i): direction") }
          if f.merchant != x["merchant"]?.stringValue { failures.append("#\(i): merchant") }
          if f.last4 != x["last4"]?.stringValue { failures.append("#\(i): last4") }
          if f.isTransfer != (x["is_transfer"]?.boolValue ?? false) { failures.append("#\(i): is_transfer") }
          if !["AED", x["currency"]?.stringValue ?? ""].contains(f.currency) { failures.append("#\(i): currency") }
          if k.marked { failures.append("#\(i): marked") }
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) failures, e.g. \(failures.prefix(12).joined(separator: "; "))")
    let summary =
      "payment texts kept \(paymentKept) (template \(templateKept), Review only \(paymentReview)); other texts dropped \(otherDropped) "
      + "\(drops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")), other texts kept \(otherKept)"
    print("[real-corpus] bank texts: \(summary)")
  }
}
