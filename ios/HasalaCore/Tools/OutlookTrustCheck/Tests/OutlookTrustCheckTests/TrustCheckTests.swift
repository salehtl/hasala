import Foundation
import OutlookTrustCheckKit
import Testing

import CoreMail

private struct Doc: Decodable {
  struct Part: Decodable {
    let text: String
    let repeatCount: Int
    enum CodingKeys: String, CodingKey {
      case text
      case repeatCount = "repeat"
    }
  }
  struct Expect: Decodable {
    let trusted: Bool
    let reason: String
    let domain: String?
  }
  struct Vector: Decodable {
    let name: String
    let provider: String?
    let headers: String?
    let headersParts: [Part]?
    let expect: Expect
    enum CodingKeys: String, CodingKey {
      case name, provider, headers, expect
      case headersParts = "headers_parts"
    }
    var raw: String { headers ?? (headersParts ?? []).map { String(repeating: $0.text, count: $0.repeatCount) }.joined() }
  }
  let vectors: [Vector]
}

private let repoRoot: URL = {
  var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("conformance/authres").path) {
    root.deleteLastPathComponent()
  }
  return root
}()

private let doc: Doc = {
  let data = try! Data(contentsOf: repoRoot.appendingPathComponent("conformance/authres/vectors.json"))
  return try! JSONDecoder().decode(Doc.self, from: data)
}()

private let outlookVectors = doc.vectors.filter { $0.provider == "outlook" }
private let gmailVectors = doc.vectors.filter { $0.provider == nil }

private func vector(_ name: String) -> String { doc.vectors.first { $0.name == name }!.raw }

private let secretBody =
  "Dear Customer, AED 1,234.56 was spent on card ending 0000 at SYNTHETIC SHOP on 01/06/2026. Ref 9876543210.\r\n"

private func eml(_ headerBlock: String, extra: String = "") -> [UInt8] {
  var h = headerBlock
  while h.hasSuffix("\r\n") { h.removeLast() }
  let added =
    "Message-ID: <synthetic-message-id-42@bank.example>\r\nDate: Mon, 1 Jun 2026 08:15:00 +0400\r\nTo: tester-local-part@outlook.example\r\nSubject: Synthetic purchase alert AED 1,234.56\r\n"
  return Array((h + "\r\n" + extra + added + "\r\n" + secretBody).utf8)
}

private let received = "Received: from mail.bank.example (192.0.2.1) by AM0PR01MB0001.eurprd01.prod.outlook.com\r\n"
private let eopAR =
  "Authentication-Results: spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=owner.example; dkim=pass header.d=owner.example; dmarc=pass action=none header.from=owner.example; compauth=pass reason=100\r\n"
private let eopFields =
  "X-MS-Exchange-Organization-AuthAs: Anonymous\r\nX-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com\r\n"
private let forgedMS =
  "Authentication-Results: spf=pass smtp.mailfrom=bank.example; dkim=pass header.d=bank.example; dmarc=pass action=none header.from=bank.example; compauth=pass reason=100\r\n"
private let forgedGoogle = "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n"
private let forgedEOP =
  "X-MS-Exchange-Organization-AuthAs: Internal\r\nX-MS-Exchange-Organization-AuthSource: relay.evil.example\r\n"
private let probeFrom = "From: Probe <probe@owner.example>\r\n"

private let spoofAllSurvive = received + eopAR + eopFields + forgedMS + forgedGoogle + forgedEOP + probeFrom
private let spoofFirewallStripped = received + eopAR + eopFields + forgedMS + forgedGoogle + probeFrom
private let spoofNoEOPAR = received + eopFields + forgedMS + forgedGoogle + probeFrom

private let bankTenant =
  received
  + "Authentication-Results: spf=pass smtp.mailfrom=bank.example; dkim=pass header.d=bank.example; dmarc=pass action=none header.from=bank.example; compauth=pass reason=100\r\n"
  + eopFields
  + "Authentication-Results: spf=pass smtp.mailfrom=bank.example; dkim=none; dmarc=bestguesspass action=none header.from=bank.example; compauth=pass reason=109\r\n"
  + "From: Bank <alerts@bank.example>\r\n"

private func run(_ inputs: [MessageInput], _ expect: TrustExpectation, domains: [String] = []) -> Report {
  TrustCheck.run(inputs, expect: expect, domains: domains)
}

private func status(_ r: Report, _ id: String) -> Status? { r.checks.first { $0.id == id }?.status }

@Suite("outlook-trust-check")
struct TrustCheckTests {
  @Test("the probe's verdict is outlookVerdict on every conformance vector", arguments: outlookVectors.map(\.name))
  func sameVerdict(_ name: String) {
    let raw = vector(name)
    let p = AuthResults.outlookTrustProbe(raw)
    let v = doc.vectors.first { $0.name == name }!
    #expect(p.analysis == AuthResults.analyzeOutlook(raw))
    #expect(p.analysis.verdict.reason.rawValue == v.expect.reason)
    #expect(p.analysis.domain == v.expect.domain)
  }

  @Test("a genuine alert prints one redacted pass line")
  func passLine() {
    let p = TrustCheck.probe(bytes: eml(vector("outlook-pass")))
    #expect(
      p.line
        == "from=bank.example from_fields=1 ar=1 forms=ms ms_index=0 topmost=yes authas=1[anonymous]@below authsource=1[ok]@below rcv0=above order=rcv0>ar:ms>as>src dmarc=pass compauth=pass reason=100 header_from=bank.example scl=- c7=none verdict=pass domain=bank.example"
    )
    #expect(p.c1 && p.c2)
  }

  @Test("genuine folder: C1, C2, C6, C7 pass; C5 needs the junk and forwarded alerts")
  func genuineFolder() {
    let r = run([MessageInput(group: .plain, bytes: eml(vector("outlook-pass")))], .pass)
    #expect(status(r, "C1") == .pass)
    #expect(status(r, "C2") == .pass)
    #expect(status(r, "C5") == .needsData)
    #expect(status(r, "C6") == .pass)
    #expect(status(r, "C7") == .pass)
    #expect(r.exitCode == 0)
  }

  @Test("junk and forwarded alerts complete C5")
  func c5() {
    let junk = eml(vector("outlook-pass"), extra: "X-MS-Exchange-Organization-SCL: 5\r\n")
    let r = run(
      [
        MessageInput(group: .plain, bytes: eml(vector("outlook-pass"))),
        MessageInput(group: .junk, bytes: junk),
        MessageInput(group: .forwarded, bytes: eml(vector("outlook-forwarded"))),
      ], .pass, domains: ["bank.example"])
    #expect(r.checks.allSatisfy { $0.status == .pass })
    #expect(r.lines[1].hasPrefix("#02 [junk] "))
    #expect(r.lines[1].contains(" scl=5 "))
    #expect(r.lines[2].contains(" forms=ms,id "))
  }

  @Test("a forwarded alert whose DKIM broke fails C5 and C6")
  func c5Broken() {
    let r = run([MessageInput(group: .forwarded, bytes: eml(vector("outlook-forwarded-dkim-broken")))], .pass)
    #expect(status(r, "C5") == .fail)
    #expect(status(r, "C6") == .fail)
    #expect(r.exitCode == 1)
  }

  @Test("a copied alert is no_eop: C2 fails in the genuine folder, C3 passes in the copied folder")
  func copied() {
    let copied = eml(vector("outlook-authas-missing"))
    let p = TrustCheck.probe(bytes: copied)
    #expect(p.analysis.verdict.reason == .noEOP)
    #expect(p.line.contains(" authas=0[-]@- "))
    let genuine = run([MessageInput(group: .plain, bytes: copied)], .pass)
    #expect(status(genuine, "C2") == .fail)
    #expect(status(genuine, "C6") == .fail)
    let untrusted = run([MessageInput(group: .plain, bytes: copied)], .untrusted)
    #expect(status(untrusted, "C3") == .pass)
    #expect(status(untrusted, "C6") == .pass)
    #expect(status(untrusted, "C1") == .needsData)
    #expect(untrusted.exitCode == 0)
  }

  @Test("multiple_ar: a forged Microsoft-form A-R below EOP's fails C1")
  func multiple() {
    let p = TrustCheck.probe(bytes: eml(vector("outlook-forged-ms-ar-below")))
    #expect(p.analysis.verdict.reason == .multipleAR)
    #expect(p.line.contains(" forms=ms,ms "))
    #expect(status(run([MessageInput(group: .plain, bytes: eml(vector("outlook-forged-ms-ar-below")))], .pass), "C1") == .fail)
  }

  @Test("the C3 probe is untrusted whichever forged headers survive")
  func spoof() {
    let cases: [(String, AuthResults.Reason)] = [
      (spoofAllSurvive, .multipleAR), (spoofFirewallStripped, .multipleAR), (spoofNoEOPAR, .fail),
    ]
    for (block, reason) in cases {
      #expect(TrustCheck.probe(bytes: eml(block)).analysis.verdict.reason == reason)
    }
    let all = TrustCheck.probe(bytes: eml(spoofAllSurvive))
    #expect(all.line.contains(" forms=ms,ms,id "))
    #expect(all.line.contains(" authas=2[anonymous,internal]@below,below "))
    #expect(all.line.contains(" authsource=2[ok,other]@below,below "))
    #expect(!all.line.contains("evil"))
    let r = run(cases.map { MessageInput(group: .plain, bytes: eml($0.0)) }, .untrusted)
    #expect(status(r, "C3") == .pass)
    let onlyEOP = received + eopAR + eopFields + probeFrom
    let leaked = run([MessageInput(group: .plain, bytes: eml(onlyEOP))], .untrusted)
    #expect(status(leaked, "C3") == .fail)
    #expect(leaked.checks.first { $0.id == "C3" }?.detail == "0/1 are not pass pass_domains=owner.example")
    #expect(leaked.exitCode == 1)
  }

  @Test("a bank tenant's second Microsoft-form A-R fails C7")
  func c7() {
    let p = TrustCheck.probe(bytes: eml(bankTenant))
    #expect(p.secondAR == .fromDomain)
    #expect(p.line.contains(" c7=from-domain "))
    #expect(status(run([MessageInput(group: .plain, bytes: eml(bankTenant))], .pass), "C7") == .fail)
  }

  @Test("--domains limits C6 to the bank's domains")
  func domains() {
    let r = run([MessageInput(group: .plain, bytes: eml(vector("outlook-pass")))], .pass, domains: ["other-bank.example"])
    #expect(status(r, "C6") == .fail)
  }

  @Test("no line names a subject, body, amount, local part, message id or date")
  func redaction() {
    let blocks = [
      vector("outlook-pass"), vector("outlook-forwarded"), vector("outlook-authas-missing"), spoofAllSurvive, bankTenant,
    ]
    let r = run(blocks.map { MessageInput(group: .plain, bytes: eml($0)) } + [MessageInput(group: .junk, bytes: nil)], .pass)
    let text = r.text
    for secret in [
      "alerts", "probe@", "tester-local-part", "Synthetic purchase", "Transaction alert", "1,234.56", "0000",
      "SYNTHETIC SHOP", "9876543210", "synthetic-message-id", "Mon,", "2026", "08:15", "192.0.2.1", "alerts@",
      "am0pr01mb0001", "AM0PR01MB0001", "eurprd01",
    ] {
      #expect(!text.contains(secret), "leaked \(secret)")
    }
    #expect(status(r, "READ") == .fail)
  }

  @Test("an empty folder needs data")
  func empty() {
    let r = run([], .pass)
    #expect(r.checks.allSatisfy { $0.status == .needsData })
    #expect(r.exitCode == 0)
    #expect(run([], .untrusted).checks.allSatisfy { $0.status == .needsData })
  }

  @Test("collect reads .eml files and the junk and forwarded subfolders, in name order")
  func collect() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for sub in ["junk", "forwarded", "other"] {
      try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try Data(eml(vector("outlook-pass"))).write(to: dir.appendingPathComponent("b.eml"))
    try Data(eml(vector("outlook-pass"))).write(to: dir.appendingPathComponent("a.EML"))
    try Data("not mail".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    try Data(eml(vector("outlook-pass"))).write(to: dir.appendingPathComponent("junk/c.eml"))
    try Data(eml(vector("outlook-forwarded"))).write(to: dir.appendingPathComponent("forwarded/d.eml"))
    try Data(eml(vector("outlook-pass"))).write(to: dir.appendingPathComponent("other/e.eml"))
    let inputs = try TrustCheck.collect(directory: dir)
    #expect(inputs.map(\.group) == [.plain, .plain, .forwarded, .junk])
    #expect(!TrustCheck.insideRepository(dir))
    #expect(TrustCheck.insideRepository(repoRoot.appendingPathComponent("conformance")))
  }

  @Test("arguments")
  func arguments() {
    #expect(TrustCheck.parse(["--expect", "pass", "/x"]) == .init(expect: .pass, domains: [], directory: "/x"))
    #expect(
      TrustCheck.parse(["/x", "--expect", "untrusted", "--domains", "A.example,b.example"])
        == .init(expect: .untrusted, domains: ["a.example", "b.example"], directory: "/x"))
    #expect(TrustCheck.parse(["/x"]) == nil)
    #expect(TrustCheck.parse(["--expect", "maybe", "/x"]) == nil)
    #expect(TrustCheck.parse(["--expect", "pass", "/x", "/y"]) == nil)
    #expect(
      TrustCheck.parse(["--provider", "gmail", "--expect", "pass", "/x"])
        == .init(expect: .pass, domains: [], directory: "/x", provider: .gmail))
    #expect(TrustCheck.parse(["--provider", "yahoo", "--expect", "pass", "/x"]) == nil)
    #expect(TrustCheck.parse(["--expect", "pass", "/x"])?.provider == .outlook)
  }

  @Test("the Gmail probe's verdict is the Gmail rule on every Gmail conformance vector", arguments: gmailVectors.map(\.name))
  func sameGmailVerdict(_ name: String) {
    let raw = vector(name)
    let p = AuthResults.gmailTrustProbe(raw)
    let v = doc.vectors.first { $0.name == name }!
    #expect(p.analysis == AuthResults.analyze(raw))
    #expect(p.analysis.verdict.reason.rawValue == v.expect.reason)
    #expect(p.analysis.domain == v.expect.domain)
  }

  @Test("a Gmail-delivered alert prints one redacted line")
  func gmailLines() {
    let direct = TrustCheck.gmailProbe(bytes: eml(vector("gmail-direct-alert")))
    #expect(
      direct.line
        == "from=bank.example from_fields=1 ar=1 forms=gmail gmail_index=0 topmost=yes dkim=pass/i/bank.example/aligned dmarc=pass spf=pass arc=- verdict=pass domain=bank.example"
    )
    #expect(direct.g1)
    let forwarded = TrustCheck.gmailProbe(bytes: eml(vector("gmail-forwarded-alert")))
    #expect(forwarded.line.contains(" ar=2 forms=gmail,other gmail_index=0 topmost=yes "))
    #expect(forwarded.line.contains(" arc=pass verdict=pass domain=bank.example"))
    let esp = TrustCheck.gmailProbe(bytes: eml(vector("gmail-esp-signature-with-spf-aligned-dmarc")))
    #expect(esp.line.contains(" dkim=pass/i/esp.example/unaligned dmarc=pass "))
    #expect(esp.line.hasSuffix(" verdict=fail domain=-"))
    let both = TrustCheck.gmailProbe(bytes: eml(vector("gmail-esp-then-bank-signature")))
    #expect(both.line.contains(" dkim=pass/i/esp.example/unaligned,pass/i/bank.example/aligned "))
    let decides = TrustCheck.gmailProbe(bytes: eml(vector("gmail-header-d-decides-over-header-i")))
    #expect(decides.line.contains(" dkim=pass/d/evil.example/unaligned "))
    let foreign = TrustCheck.gmailProbe(bytes: eml(vector("gmail-shape-foreign-above")))
    #expect(foreign.line.contains(" forms=other,gmail gmail_index=1 topmost=no "))
    #expect(!foreign.g1)
    let outlook = TrustCheck.gmailProbe(bytes: eml(vector("outlook-pass")))
    #expect(outlook.line.contains(" forms=ms gmail_index=- topmost=no dkim=- dmarc=- spf=- arc=- verdict=no_ar "))
  }

  @Test("Gmail folders: G1 and G2 for genuine alerts, G3 for copied or forged mail")
  func gmailFolders() {
    let direct = MessageInput(group: .plain, bytes: eml(vector("gmail-direct-alert")))
    let forwarded = MessageInput(group: .forwarded, bytes: eml(vector("gmail-forwarded-alert")))
    let genuine = TrustCheck.runGmail([direct, forwarded], expect: .pass, domains: ["bank.example"])
    #expect(status(genuine, "G1") == .pass)
    #expect(status(genuine, "G2") == .pass)
    #expect(status(genuine, "G3") == .needsData)
    #expect(genuine.lines[1].hasPrefix("#02 [forwarded] "))
    #expect(genuine.exitCode == 0)
    let esp = TrustCheck.runGmail([MessageInput(group: .plain, bytes: eml(vector("gmail-esp-signature-with-spf-aligned-dmarc")))], expect: .pass)
    #expect(status(esp, "G1") == .pass)
    #expect(status(esp, "G2") == .fail)
    #expect(esp.exitCode == 1)
    #expect(status(TrustCheck.runGmail([direct], expect: .pass, domains: ["other-bank.example"]), "G2") == .fail)
    let copied = TrustCheck.runGmail(
      [MessageInput(group: .plain, bytes: eml(vector("gmail-shape-copy-above"))), MessageInput(group: .plain, bytes: eml(vector("no-ar-header")))],
      expect: .untrusted)
    #expect(status(copied, "G3") == .pass)
    #expect(status(copied, "G1") == .needsData)
    #expect(copied.exitCode == 0)
    let leaked = TrustCheck.runGmail([direct], expect: .untrusted)
    #expect(status(leaked, "G3") == .fail)
    #expect(leaked.checks.first { $0.id == "G3" }?.detail == "0/1 are not pass pass_domains=bank.example")
    #expect(TrustCheck.runGmail([], expect: .pass).checks.allSatisfy { $0.status == .needsData })
  }

  @Test("no Gmail line names a subject, body, amount, local part, message id, date, address or signature")
  func gmailRedaction() {
    let names = ["gmail-direct-alert", "gmail-forwarded-alert", "gmail-forwarded-dkim-broken", "gmail-esp-then-bank-signature"]
    let r = TrustCheck.runGmail(
      names.map { MessageInput(group: .plain, bytes: eml(vector($0))) } + [MessageInput(group: .junk, bytes: nil)], expect: .pass)
    let text = r.text
    for secret in [
      "alerts", "user@", "synthetic.user", "tester-local-part", "Synthetic purchase", "Transaction alert", "1,234.56", "0000",
      "SYNTHETIC SHOP", "9876543210", "synthetic-message-id", "Mon,", "2026", "08:15", "192.0.2", "selector1", "c3ludGhl",
      "forwarder.example", "ZXNwc2ln",
    ] {
      #expect(!text.contains(secret), "leaked \(secret)")
    }
    #expect(status(r, "READ") == .fail)
  }

  @Test("C4: the same order in $value and internetMessageHeaders matches; a moved A-R does not")
  func headerOrder() {
    let raw = vector("outlook-pass")
    let listed: [(name: String, value: String)] = [
      ("Received", "from mail.bank.example (192.0.2.1)  by AM0PR01MB0001.eurprd01.prod.outlook.com; Mon, 1 Jun 2026 00:00:00 +0000"),
      ("Authentication-Results", "spf=pass smtp.mailfrom=bank.example; dkim=pass header.d=bank.example; dmarc=pass action=none header.from=bank.example;compauth=pass reason=100"),
      ("X-MS-Exchange-Organization-AuthAs", "Anonymous"),
      ("X-MS-Exchange-Organization-AuthSource", "AM0PR01MB0001.eurprd01.prod.outlook.com"),
      ("From", "Bank <alerts@bank.example>"),
    ]
    let same = AuthResults.outlookOrderComparison(rawHeaders: raw, listed: listed)
    #expect(same.orderMatch && same.receivedSame)
    #expect(same.line.hasSuffix(" listed_order=rcv0>ar:ms>as>src order_match=yes rcv0=same"))
    #expect(!same.line.contains("alerts@"))
    let moved = [listed[0], listed[2], listed[3], listed[1], listed[4]]
    let differs = AuthResults.outlookOrderComparison(rawHeaders: raw, listed: moved)
    #expect(!differs.orderMatch)
    #expect(differs.line.contains(" order_match=no "))
    let otherReceived = [("Received", "from elsewhere.example by relay.example")] + listed.dropFirst()
    #expect(!AuthResults.outlookOrderComparison(rawHeaders: raw, listed: Array(otherReceived)).receivedSame)
    #expect(!AuthResults.outlookOrderComparison(rawHeaders: raw, listed: []).orderMatch)
  }
}
