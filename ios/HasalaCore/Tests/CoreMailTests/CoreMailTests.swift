// CoreMail: the Gmail Authentication-Results trust rule (every adversarial golden of
// reference/ledgerd-client/src/mail/authres.test.ts, plus the non-ASCII whitespace and
// case-folding behaviour pinned explicitly), the header block slicer and the forwarder list.
// Every fixture is synthetic.
import Testing

@testable import CoreMail

private func block(_ lines: String...) -> String { lines.joined(separator: "\r\n") + "\r\n\r\n" }
private func verdict(_ raw: String) -> (Bool, AuthResults.Reason) {
  let v = AuthResults.gmailVerdict(raw)
  return (v.trusted, v.reason)
}

@Suite("Authentication-Results")
struct AuthResultsTests {
  @Test("a single passing mx.google.com A-R with dkim=pass is trusted")
  func dkimPass() {
    let raw = block(
      "Authentication-Results: mx.google.com;", "       dkim=pass header.i=@bank.example header.d=bank.example;",
      "       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=bank.example", "From: Bank <alerts@bank.example>",
      "Subject: Transaction alert")
    #expect(verdict(raw) == (true, .pass))
    #expect(AuthResults.verifiedDomain(raw) == "bank.example")
  }

  @Test("dmarc=pass alone trusts, with the domain from header.from, lower-cased")
  func dmarcOnly() {
    let raw = block(
      "Authentication-Results: mx.google.com;", "       dkim=neutral;", "       dmarc=pass header.from=Bank.Example",
      "From: Bank <alerts@bank.example>")
    #expect(verdict(raw) == (true, .pass))
    #expect(AuthResults.verifiedDomain(raw) == "bank.example")
  }

  @Test("spf=pass alone is never trusted")
  func spfOnly() {
    let raw = block("Authentication-Results: mx.google.com; spf=pass smtp.mailfrom=alerts@bank.example")
    #expect(verdict(raw) == (false, .fail))
    #expect(AuthResults.verifiedDomain(raw) == nil)
  }

  @Test("no A-R, or only a foreign authserv-id, is no_ar")
  func noAR() {
    #expect(verdict(block("From: someone@bank.example", "Subject: hi")) == (false, .noAR))
    let foreign = block("Authentication-Results: mail.attacker.test; dkim=pass header.d=bank.example", "From: x")
    #expect(verdict(foreign) == (false, .noAR))
    #expect(AuthResults.verifiedDomain(foreign) == nil)
  }

  @Test("two mx.google.com A-Rs is multiple_ar")
  func multiple() {
    let raw = block(
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: x")
    #expect(verdict(raw) == (false, .multipleAR))
    #expect(AuthResults.verifiedDomain(raw) == nil)
  }

  @Test("a forged foreign A-R above the real one is not_topmost; one below is fine")
  func topmost() {
    let above = block(
      "Authentication-Results: attacker.test; dkim=pass header.d=bank.example",
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: x")
    #expect(verdict(above) == (false, .notTopmost))
    #expect(AuthResults.verifiedDomain(above) == nil)
    let below = block(
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "Authentication-Results: some-forwarder.test; dkim=pass header.d=bank.example", "From: x")
    #expect(verdict(below) == (true, .pass))
    #expect(AuthResults.verifiedDomain(below) == "bank.example")
  }

  @Test("dkim=fail with no dmarc pass, or dkim=pass with no d=, is fail")
  func failures() {
    let fail = block(
      "Authentication-Results: mx.google.com;", "       dkim=fail header.d=bank.example;",
      "       dmarc=fail header.from=bank.example", "From: x")
    #expect(verdict(fail) == (false, .fail))
    let noD = block("Authentication-Results: mx.google.com; dkim=pass header.i=@bank.example", "From: x")
    #expect(verdict(noD) == (false, .fail))
    #expect(AuthResults.verifiedDomain(noD) == nil)
    let dmarcNoFrom = block("Authentication-Results: mx.google.com; dmarc=pass", "From: x")
    #expect(verdict(dmarcNoFrom) == (false, .fail))
  }

  @Test("folded values, CFWS comments (nested, holding ';') and quoted strings parse")
  func syntax() {
    let folded = block(
      "Authentication-Results: mx.google.com;", "\tdkim=pass", "        header.d=bank.example;",
      "\tspf=pass (google.com: domain of alerts@bank.example designates ...)", "        smtp.mailfrom=alerts@bank.example;",
      "\tdmarc=pass header.from=bank.example", "From: x")
    #expect(verdict(folded) == (true, .pass))
    #expect(AuthResults.verifiedDomain(folded) == "bank.example")
    let comments = block(
      "Authentication-Results: mx.google.com (Google mail server);",
      "       dkim=pass (2048-bit key; unprotected) header.d=bank.example;",
      "       dmarc=pass (policy applied (nested comment)) header.from=bank.example", "From: x")
    #expect(verdict(comments) == (true, .pass))
    let semis = block("Authentication-Results: mx.google.com;", "       dkim=pass (key; note; with; semicolons) header.d=bank.example")
    #expect(AuthResults.verifiedDomain(semis) == "bank.example")
    let quoted = block("Authentication-Results: \"mx.google.com\"; dkim=\"pass\" header.d=\"bank.example\"")
    #expect(AuthResults.verifiedDomain(quoted) == "bank.example")
    let address = block("Authentication-Results: mx.google.com; dmarc=pass header.from=alerts@Bank.Example")
    #expect(AuthResults.verifiedDomain(address) == "bank.example")
  }

  @Test("bare authserv-id only; ARC-Authentication-Results is a different field")
  func names() {
    #expect(verdict(block("Authentication-Results: mx.google.com:25; dkim=pass header.d=bank.example")) == (false, .noAR))
    #expect(verdict(block("ARC-Authentication-Results: i=1; mx.google.com; dkim=pass header.d=bank.example")) == (false, .noAR))
    let upper = block("AUTHENTICATION-RESULTS: MX.GOOGLE.COM; dkim=PASS header.d=Bank.Example")
    #expect(verdict(upper) == (true, .pass))
    #expect(AuthResults.verifiedDomain(upper) == "bank.example")
    #expect(AuthResults.verifiedDomain(block("Authentication-Results: mx.google.com; dkim/1=pass header.d=bank.example")) == "bank.example")
  }

  @Test("domains must be plain LDH names with a dot")
  func domains() {
    for bad in ["bank", "bank.example:25", "-bank.example", "bank-.example", "bank..example", "b ank.example", "bänk.example"] {
      let raw = block("Authentication-Results: mx.google.com; dkim=pass header.d=\(bad)")
      #expect(verdict(raw) == (false, .fail), "\(bad)")
    }
    let long = String(repeating: "a", count: 64) + ".example"
    #expect(verdict(block("Authentication-Results: mx.google.com; dkim=pass header.d=\(long)")) == (false, .fail))
  }

  @Test("bounds: over-large is parse_error, too-deep folding is parse_error, empty is no_ar; nothing throws")
  func bounds() {
    #expect(verdict("X-Pad: " + String(repeating: "a", count: 300_000) + "\r\n\r\n") == (false, .parseError))
    var deep = ["Authentication-Results: mx.google.com; dkim=pass header.d=bank.example"]
    deep += Array(repeating: " x", count: AuthResults.maxFieldLines + 1)
    #expect(verdict(deep.joined(separator: "\r\n")) == (false, .parseError))
    #expect(verdict("") == (false, .noAR))
    let junk = verdict("\u{0}\u{1} not a header at all \n\n more junk")
    #expect(!junk.0)
    // A body A-R after the blank line is not a header.
    let body = "From: x\r\n\r\nAuthentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n"
    #expect(verdict(body) == (false, .noAR))
    // The bound is in UTF-16 code units, as in the twin: 100,000 astral scalars are 200,000.
    #expect(verdict("X: " + String(repeating: "🏦", count: 140_000)) == (false, .parseError))
  }

  /// Pinned rather than inherited (inventory client-core-b §3): JavaScript's `trim` removes
  /// U+00A0 and U+FEFF, and its `toLowerCase` maps U+212A KELVIN SIGN to `k`. The port keeps
  /// both, so its verdict is the twin's on every input.
  @Test("non-ASCII whitespace and case folding behave as in the TypeScript twin")
  func jsSemantics() {
    // A field name padded with NBSP still names an A-R (so a forged one below Gmail's is
    // counted, and the result fails closed as multiple_ar).
    let nbspName = block(
      "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example",
      "\u{A0}Authentication-Results: mx.google.com; dkim=pass header.d=evil.example")
    #expect(verdict(nbspName) == (false, .multipleAR))
    // A BOM before the value is trimmed like a space.
    let bom = block("Authentication-Results:\u{FEFF} mx.google.com; dkim=pass header.d=bank.example")
    #expect(verdict(bom) == (true, .pass))
    // NBSP around a domain value is trimmed.
    let nbspDomain = block("Authentication-Results: mx.google.com; dkim=pass header.d=\"\u{A0}bank.example\u{A0}\"")
    #expect(AuthResults.verifiedDomain(nbspDomain) == "bank.example")
    // U+212A lower-cases to `k`, so "d\u{212A}im" is dkim, as it is to the twin.
    let kelvin = block("Authentication-Results: mx.google.com; d\u{212A}im=pass header.d=bank.example")
    #expect(verdict(kelvin) == (true, .pass))
    // NBSP is NOT a token separator: "dkim=pass\u{A0}header.d=..." is one token.
    let glued = block("Authentication-Results: mx.google.com; dkim=pass\u{A0}header.d=bank.example")
    #expect(verdict(glued) == (false, .fail))
  }

  @Test("CR, LF and CRLF all end a header line")
  func lineEnds() {
    let cr = "Authentication-Results: mx.google.com;\r dkim=pass header.d=bank.example\r\rbody"
    #expect(verdict(cr) == (true, .pass))
    let lf = "Authentication-Results: mx.google.com;\n dkim=pass header.d=bank.example\n\nbody"
    #expect(verdict(lf) == (true, .pass))
  }
}

@Suite("header block and forwarders")
struct MailHeaderTests {
  @Test("the header block ends at the first blank line of any style")
  func headerBlock() {
    #expect(MailHeaders.headerBlock("A: 1\r\nB: 2\r\n\r\nbody\r\n\r\n") == "A: 1\r\nB: 2")
    #expect(MailHeaders.headerBlock("A: 1\nB: 2\n\nbody") == "A: 1\nB: 2")
    #expect(MailHeaders.headerBlock("A: 1\rB: 2\r\rbody") == "A: 1\rB: 2")
    #expect(MailHeaders.headerBlock("A: 1\r\nB: 2") == "A: 1\r\nB: 2")
    #expect(MailHeaders.headerBlock("") == "")
    #expect(MailHeaders.headerBlock(rawMessage: Array("A: 1\r\n\r\nbody".utf8)) == "A: 1")
    // One leading BOM is dropped, as TextDecoder drops it: a BOM then a blank line is an
    // empty header block, not a block that runs on into the body.
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    #expect(MailHeaders.headerBlock(rawMessage: bom + Array("\r\n\r\nA: 1\r\n\r\n".utf8)) == "")
    #expect(MailHeaders.headerBlock(rawMessage: bom + Array("A: 1\r\n\r\nbody".utf8)) == "A: 1")
    #expect(MailHeaders.headerBlock(rawMessage: bom + bom + Array("A: 1\r\n\r\nbody".utf8)) == "\u{FEFF}A: 1")
    // A large body no longer counts against the A-R bound.
    let big = "Authentication-Results: mx.google.com; dkim=pass header.d=bank.example\r\n\r\n"
      + String(repeating: "x", count: 900_000)
    #expect(AuthResults.gmailVerdict(MailHeaders.headerBlock(big)).trusted)
  }

  @Test("forwarders, and their subdomains, are recognised; banks are not")
  func forwarders() {
    #expect(ForwarderDomains.v1.count == 18)
    #expect(ForwarderDomains.v1 == ForwarderDomains.v1.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    for d in ["gmail.com", "GMAIL.COM", " gmail.com. ", "mail.icloud.com", "proton.me"] {
      #expect(ForwarderDomains.contains(d), "\(d)")
    }
    for d in ["emiratesnbd.com", "dib.ae", "notgmail.com", "gmail.com.evil.example", "", "."] {
      #expect(!ForwarderDomains.contains(d), "\(d)")
    }
  }
}
