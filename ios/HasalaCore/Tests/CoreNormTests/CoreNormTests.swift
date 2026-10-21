// Unit vectors for CoreNorm: the clauses of the normalizer contract no end-to-end fixture can
// reach (a port of the ledgerd TypeScript client's src/norm/norm.test.ts, each of which pins a
// mutation that survived the whole corpus), plus the freshness check of the generated
// charset tables against conformance/normalizer/charset-tables.ts, which they are generated from.
import Foundation
import Testing

@testable import CoreNorm

private func bytes(_ b: UInt8...) -> [UInt8] { b }
private func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }
private func cps(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
private let at: Int64 = 1_785_542_400_000  // 2026-08-01T00:00:00Z

@Suite("stage 3: WHATWG UTF-8 substitution")
struct UTF8Tests {
  @Test(
    "one U+FFFD per maximal subpart",
    arguments: [
      (bytes(0x41, 0xe2, 0x82), [0x41, 0xfffd]),
      (bytes(0x41, 0xf0, 0x9f, 0x92), [0x41, 0xfffd]),
      (bytes(0xe2, 0x82, 0x41, 0x42), [0xfffd, 0x41, 0x42]),
      (bytes(0x41, 0x80, 0x42), [0x41, 0xfffd, 0x42]),
      (bytes(0x41, 0xc0, 0x80, 0x42), [0x41, 0xfffd, 0xfffd, 0x42]),
      (bytes(0x41, 0xed, 0xa0, 0x80, 0x42), [0x41, 0xfffd, 0xfffd, 0xfffd, 0x42]),
      (bytes(0x41, 0xf5, 0x80, 0x80, 0x80, 0x42), [0x41, 0xfffd, 0xfffd, 0xfffd, 0xfffd, 0x42]),
    ] as [([UInt8], [UInt32])])
  func vectors(_ input: [UInt8], _ want: [UInt32]) {
    #expect(cps(NormText.decodeUTF8(input)) == want)
  }

  @Test("a leading BOM is passed through, never stripped")
  func bom() {
    #expect(cps(NormText.decodeUTF8(bytes(0xef, 0xbb, 0xbf, 0x41))) == [0xfeff, 0x41])
  }
}

@Suite("stage 2: charset resolution")
struct CharsetTests {
  @Test("windows-1256, the corpus's only legacy charset, decodes from the table")
  func windows1256() throws {
    guard case .singleByte(let t) = Charset.classify("windows-1256") else {
      Issue.record("windows-1256 is not a single-byte table")
      return
    }
    #expect(Charset.decodeSingleByte(table: t, bytes(0xc7, 0xe1, 0xda, 0xd1, 0xc8, 0xed)) == "العربي")
    #expect(Charset.classify("WINDOWS-1256") == .singleByte(t))
  }

  @Test("iso-8859-1 is true Latin-1, and iso8859-1 (no hyphen) is windows-1252")
  func latin1() {
    guard case .singleByte(let l) = Charset.classify("iso-8859-1"),
      case .singleByte(let w) = Charset.classify("iso8859-1")
    else {
      Issue.record("labels did not resolve to tables")
      return
    }
    #expect(cps(Charset.decodeSingleByte(table: l, [0x80])) == [0x80])
    #expect(Charset.decodeSingleByte(table: w, [0x80]) == "€")
  }

  @Test("utf-8 and us-ascii pass through; unknown labels are unresolved; multi-byte is refused")
  func kinds() throws {
    #expect(Charset.classify("utf-8") == .passthrough)
    #expect(Charset.classify("US-ASCII") == .passthrough)
    #expect(Charset.classify("x-nope") == .unresolved)
    #expect(Charset.classify("never-heard-of-it") == .unresolved)
    #expect(Charset.classify("utf-16") == .unsupported)
    #expect(Charset.classify("shift_jis") == .unsupported)
    // A non-ASCII label never matches an ASCII one, even where `String ==` would say so.
    #expect(Charset.classify("utf\u{2010}8") == .unresolved)
    let raw = utf8("From: a@b.c\r\nContent-Type: text/plain; charset=utf-16\r\n\r\nhi\r\n")
    #expect(throws: NormalizeError.unsupportedCharset("utf-16")) {
      try Normalizer.normalize(version: 1, raw: raw, receivedAtMs: at)
    }
  }
}

@Suite("transfer encodings")
struct TransferTests {
  @Test("base64 skips ASCII whitespace anywhere and is otherwise strict")
  func base64() throws {
    for payload in ["SGVsbG8gd29ybGQ=", "SGVsbG8g d29ybGQ=", "SGVsbG8g\td29ybGQ=", "SGVsbG8g\r\n  d29ybGQ="] {
      #expect(try MIME.decodeBase64(utf8(payload)) == utf8("Hello world"))
    }
    for bad in ["SGVsbG8gd29ybGQ", "SGVsbG8*d29ybGQ=", "SGVsbG8gd29ybG", "SGVsbG8=extra"] {
      #expect(throws: MIMEFailure.leafDecode) { try MIME.decodeBase64(utf8(bad)) }
    }
  }

  @Test("quoted-printable reproduces Go's documented leniency")
  func quotedPrintable() throws {
    func dec(_ s: String) throws -> String { NormText.decodeUTF8(try MIME.decodeQuotedPrintable(utf8(s))) }
    #expect(try dec("AAA=\r\nBBB") == "AAABBB")
    #expect(try dec("AAA=\nBBB") == "AAABBB")
    #expect(try dec("A=ZZB\r\n") == "A=ZZB\r\n")
    #expect(try dec("x=4") == "x=4")
    #expect(try dec("AB=") == "AB")
    #expect(throws: MIMEFailure.leafDecode) { try MIME.decodeQuotedPrintable(utf8("AB\r\n=")) }
    #expect(try dec("A  \r\nB") == "A\r\nB")
    #expect(try dec("A  =\r\nB") == "A  B")
    #expect(try dec("A=  \r\nB") == "AB")
    #expect(try dec("x=c3=a9y") == "xéy")
    #expect(try dec("x=C3=A9y") == "xéy")
    #expect(try MIME.decodeQuotedPrintable(bytes(0x78, 0xc3, 0xa9, 0x79)) == bytes(0x78, 0xc3, 0xa9, 0x79))
    #expect(throws: MIMEFailure.leafDecode) { try MIME.decodeQuotedPrintable(bytes(0x78, 0x01, 0x79)) }
    #expect(throws: MIMEFailure.leafDecode) { try MIME.decodeQuotedPrintable(bytes(0x78, 0x7f, 0x79)) }
  }
}

@Suite("headers")
struct HeaderTests {
  @Test("folding, first field wins, and the three fatal shapes")
  func readHeader() throws {
    let h = try MIME.readHeader(utf8("Subject: One\r\n  Two\r\n\r\nbody"), 0)
    #expect(h.fields.count == 1)
    #expect(h.get("subject") == utf8("One Two"))
    #expect(try MIME.readHeader(utf8("Subject: First\r\nSubject: Second\r\n\r\n"), 0).get("subject") == utf8("First"))
    for bad in [" leading\r\nFrom: a@b.c\r\n\r\n", "From: a@b.c\r\nNOCOLON\r\n\r\n", "From: a@b.c\r\nBad Key: v\r\n\r\n"] {
      #expect(throws: MIMEFailure.parse) { try MIME.readHeader(utf8(bad), 0) }
    }
  }

  @Test("RFC 2047: adjacent words join with no separator; a bad word stays raw")
  func words() throws {
    #expect(try MIME.decodeWords(utf8("=?utf-8?B?QUJD?= =?utf-8?B?REVG?=")) == "ABCDEF")
    #expect(try MIME.decodeWords(utf8("=?x-nope?B?QUJD?=")) == "=?x-nope?B?QUJD?=")
    #expect(try MIME.decodeWords(utf8("=?utf-8?B?!!!?=")) == "=?utf-8?B?!!!?=")
    #expect(try MIME.decodeWords(utf8("=?iso-8859-1?Q?a=E9b?=")) == "aéb")
    #expect(cps(try MIME.decodeWords(utf8("=?us-ascii?B?YcO/Yg==?="))) == [0x61, 0xfffd, 0xfffd, 0x62])
    #expect(throws: MIMEFailure.unsupportedCharset("shift_jis")) {
      try MIME.decodeWords(utf8("=?Shift_JIS?B?QUJD?="))
    }
  }

  @Test("From is reduced to the bare address; junk is kept, not dropped")
  func bareAddress() {
    #expect(MIME.bareAddress("Alice B <a@b.c>") == "a@b.c")
    #expect(MIME.bareAddress("\"B, Alice\" <a@b.c>") == "a@b.c")
    #expect(MIME.bareAddress("a@b.c, d@e.f") == "a@b.c")
    #expect(MIME.bareAddress("<a@b.c>") == "a@b.c")
    #expect(MIME.bareAddress("junk <a@b.c> junk") == "a@b.c")
    #expect(MIME.bareAddress("not an address") == "not an address")
    #expect(MIME.bareAddress("") == "")
  }

  @Test("Content-Type: a trailing semicolon is tolerated; what Go rejects yields nil")
  func mediaType() throws {
    let mt = try #require(try MIME.parseMediaType(utf8("text/html; charset=utf-8;")))
    #expect(mt.type == utf8("text/html"))
    #expect(mt.params == ["charset": "utf-8"])
    #expect(try MIME.parseMediaType(utf8("text/html (html); charset=utf-8")) == nil)
    // RFC 2231 continuations, and a duplicate parameter with a different value.
    let cont = try #require(try MIME.parseMediaType(utf8("text/plain; name*0=\"ab\"; name*1=cd; title*=utf-8''x%41y")))
    #expect(cont.params["name"] == "abcd")
    #expect(cont.params["title"] == "xAy")
    #expect(try MIME.parseMediaType(utf8("text/plain; a=1; a=2")) == nil)
  }
}

@Suite("stages 5-10")
struct StageTests {
  @Test("the explicit trim set trims exactly its eight characters")
  func trim() {
    #expect(NormText.trimExplicit("\u{0a}\u{09} \u{a0}\u{feff}X\u{feff}\u{a0} \u{0d}") == "X")
    for keep in ["\u{85}", "\u{200a}", "\u{202f}", "\u{2000}", "\u{205f}"] {
      #expect(NormText.trimExplicit(keep + "X" + keep) == keep + "X" + keep)
    }
  }

  @Test("entities decode in ONE pass that never rescans")
  func entities() throws {
    let raw = utf8("From: a@b.c\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>&amp;lt; &amp;amp; &copy;</p>\r\n")
    #expect(try Normalizer.normalize(version: 1, raw: raw, receivedAtMs: at).text == "&lt; &amp; &copy;")
  }

  @Test("script and style blocks, block tags and the generic tag rule")
  func html() throws {
    let raw = utf8(
      "Content-Type: text/html\r\n\r\nA<SCRIPT type=x>bad</Script>B<style>x</STYLE>C<br>D<br/>E</p>F<a href=1>G</a>H<>I")
    #expect(try Normalizer.normalize(version: 1, raw: raw, receivedAtMs: at).text == "A B C\nD\nE\nF\nG\nH<>I")
  }

  @Test("hostile HTML stays linear: unclosed tags and script openers")
  func hostileHTML() throws {
    let unclosed = String(repeating: "<script ", count: 40_000) + String(repeating: "<", count: 200_000)
    let raw = utf8("Content-Type: text/html\r\n\r\n" + unclosed)
    let start = ContinuousClock.now
    _ = try Normalizer.normalize(version: 1, raw: raw, receivedAtMs: at)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @Test("hostile plain text and headers stay linear: many short lines, many failing words")
  func hostileLinear() throws {
    // 500,000 one-character lines: the line join once re-scanned its output per line.
    let lines = utf8("Content-Type: text/plain\r\n\r\n" + String(repeating: "x\n", count: 500_000))
    var start = ContinuousClock.now
    let text = try Normalizer.normalize(version: 1, raw: lines, receivedAtMs: at).text
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(text.utf8.count == 999_999)
    // 250,000 encoded-word openers that never complete: each failure once copied the rest.
    let words = utf8(String(repeating: "=?utf-8?B?", count: 250_000))
    start = ContinuousClock.now
    let decoded = try MIME.decodeWords(words)
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(decoded.utf8.count == words.count)
  }

  @Test("forward unwrapping: a marker alone still sets forwarded; both header layouts recover")
  func unwrap() {
    let f = Unwrap.unwrapForward(from: "outer@x.y", subject: "Fwd: Subj", body: "Begin forwarded message:\n> From: inner@a.b\n> body")
    #expect(f.found)
    #expect(f.from == "outer@x.y")
    #expect(f.subject == "Subj")
    #expect(f.body == "Begin forwarded message:\n> From: inner@a.b\n> body")
    let gmail = Unwrap.unwrapForward(
      from: "o@x.y", subject: "Fwd: S", body: "---------- Forwarded message ---------\nFrom: i@a.b\nSubject: Inner\n\nBODY")
    #expect(gmail.from == "i@a.b")
    #expect(gmail.subject == "Inner")
    #expect(gmail.body == "BODY")
    let apple = Unwrap.unwrapForward(
      from: "o@x.y", subject: "Fwd: S", body: "Begin forwarded message:\nFrom:\ni@a.b\nSubject:\nInner\n\nBODY")
    #expect(apple.from == "i@a.b")
    #expect(apple.subject == "Inner")
    #expect(apple.body == "BODY")
    // A header value holding CR or U+2028 is not a header line (`.` excludes them).
    let cr = Unwrap.unwrapForward(from: "o@x.y", subject: "S", body: "Begin forwarded message:\nFrom: i@a\rb\nBODY")
    #expect(cr.from == "o@x.y")
  }

  @Test("forward dates: four closed layouts, naive UTC, never a general parser")
  func forwardDates() {
    func iso(_ s: String) -> String? { Unwrap.parseForwardDate(s).map(Normalizer.format) }
    #expect(iso("Feb 8, 2026 at 12:52 PM") == "2026-02-08T12:52:00Z")
    #expect(iso("Sun, Feb 8, 2026 at 12:52 PM") == "2026-02-08T12:52:00Z")
    #expect(iso("8 February 2026 at 15:36:02") == "2026-02-08T15:36:02Z")
    #expect(iso("8 February 2026 at 15:36") == "2026-02-08T15:36:00Z")
    #expect(iso("8 February 2026 at 15:36:02 GST") == "2026-02-08T15:36:02Z")
    #expect(iso("Feb 8, 2026 at 12:52 PM GMT+4") == "2026-02-08T12:52:00Z")
    #expect(iso("Feb 8, 2026 at 12:52\u{202F}PM") == "2026-02-08T12:52:00Z")
    #expect(iso("Feb 8, 2026 at 12:52 pm") == nil)
    #expect(iso("Feb 8, 2026 at 12:05 AM") == "2026-02-08T00:05:00Z")
    #expect(iso("14 February 2026 at 6:12:38 PM GST") == nil)
    #expect(iso("2026-03-03T14:07:00Z") == nil)
    #expect(iso("Mar 3, 2026 2:07 PM") == nil)
    #expect(iso("March 3, 2026") == nil)
    #expect(iso("Feb 30, 2026 at 1:00 PM") == nil)
    #expect(iso("8 February 2026 at 15:61") == nil)
    #expect(iso("Xyz 8, 2026 at 12:52 PM") == nil)
    #expect(iso("Feb 8, 2026 at 13:52 PM") == nil)
    // Years are literal, as in Go (the JavaScript twin's Date.UTC would read 0050 as 1950).
    #expect(iso("8 February 0050 at 15:36") == "0050-02-08T15:36:00Z")
  }

  @Test("invalid UTF-8 in a header becomes U+FFFD; text is always valid UTF-8")
  func invalidHeaderBytes() throws {
    let word = Data([0x41, 0xc3, 0x28, 0x42]).base64EncodedString()
    let raw1 = utf8("From: a@b.c\r\nSubject: =?utf-8?B?\(word)?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody\r\n")
    #expect(cps(try Normalizer.normalize(version: 1, raw: raw1, receivedAtMs: at).subject) == [0x41, 0xfffd, 0x28, 0x42])
    let raw2 = utf8("From: a@b.c\r\nSubject: A") + [0xff] + utf8("B\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody\r\n")
    #expect(cps(try Normalizer.normalize(version: 1, raw: raw2, receivedAtMs: at).subject) == [0x41, 0xfffd, 0x42])
    let raw3 = utf8("From: a@b.c\r\nSubject: مرحبا DIB\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody\r\n")
    #expect(try Normalizer.normalize(version: 1, raw: raw3, receivedAtMs: at).subject == "مرحبا DIB")
    let raw4 = utf8("From: a@b.c\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nA") + [0xff] + utf8("B\r\n")
    #expect(cps(try Normalizer.normalize(version: 1, raw: raw4, receivedAtMs: at).text) == [0x41, 0xfffd, 0x42])
  }

  @Test("the received time is formatted as RFC 3339 UTC whole seconds")
  func receivedFormat() throws {
    let raw = utf8("Content-Type: text/plain\r\n\r\nx\r\n")
    let r = try Normalizer.normalize(version: 1, raw: raw, receivedAtMs: at + 999)
    #expect(r.emailDate == "2026-08-01T00:00:00Z")
    #expect(r.dateSource == .received)
    #expect(Normalizer.format(epochMs: -1) == "1969-12-31T23:59:59Z")
  }
}

@Suite("CharsetTables.swift is current")
struct CharsetTablesFreshnessTests {
  /// conformance/normalizer/charset-tables.ts, found by walking up from this file.
  static func tsSource() throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      let f = dir.appendingPathComponent("conformance/normalizer/charset-tables.ts")
      if FileManager.default.fileExists(atPath: f.path) { return try String(contentsOf: f, encoding: .utf8) }
      dir.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
  }

  static func block(_ lines: [String], _ name: String) -> [String] {
    guard let start = lines.firstIndex(where: { $0.hasPrefix("const \(name):") }) else { return [] }
    var out: [String] = []
    for l in lines[(start + 1)...] {
      if l == "];" || l == "};" { break }
      out.append(l)
    }
    return out
  }

  /// A decoder for the JavaScript string literals the Go writer emits, written independently of
  /// ios/tools/charset-tables/generate.swift so the two can disagree.
  static func decodeLiteral(_ line: String) -> [UInt16] {
    var s = Substring(line.trimmingCharacters(in: .whitespaces))
    if s.hasSuffix(",") { s = s.dropLast() }
    s = s.dropFirst().dropLast()  // the quotes
    var out: [UInt16] = []
    var i = s.unicodeScalars.startIndex
    let u = s.unicodeScalars
    while i < u.endIndex {
      let c = u[i]
      i = u.index(after: i)
      if c != "\\" {
        out.append(UInt16(c.value))
        continue
      }
      let e = u[i]
      i = u.index(after: i)
      switch e {
      case "t": out.append(9)
      case "n": out.append(10)
      case "r": out.append(13)
      case "u":
        precondition(u[i] == "{")
        i = u.index(after: i)
        var hex = ""
        while u[i] != "}" {
          hex.unicodeScalars.append(u[i])
          i = u.index(after: i)
        }
        i = u.index(after: i)
        out.append(UInt16(hex, radix: 16)!)
      default: out.append(UInt16(e.value))  // \" and \\
      }
    }
    return out
  }

  static func labels(_ lines: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    for l in lines {
      let parts = l.trimmingCharacters(in: .whitespaces).split(separator: "\"")
      guard parts.count == 2, let n = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ":, "))) else {
        continue
      }
      out[String(parts[0])] = n
    }
    return out
  }

  static func list(_ lines: [String]) -> Set<String> {
    Set(lines.compactMap { l in
      let parts = l.trimmingCharacters(in: .whitespaces).split(separator: "\"", omittingEmptySubsequences: false)
      return parts.count >= 3 ? String(parts[1]) : nil
    })
  }

  @Test("tables, label maps and label lists equal the TypeScript twin's")
  func fresh() throws {
    let lines = try Self.tsSource().components(separatedBy: "\n")
    let tables = Self.block(lines, "TABLES").map(Self.decodeLiteral)
    #expect(tables.count == CharsetTables.tables.count)
    #expect(tables == CharsetTables.tables)
    #expect(Self.labels(Self.block(lines, "SINGLE_BYTE")) == CharsetTables.singleByte)
    #expect(Self.labels(Self.block(lines, "WORD_SINGLE_BYTE")) == CharsetTables.wordSingleByte)
    #expect(Self.list(Self.block(lines, "UNSUPPORTED")) == CharsetTables.unsupported)
    #expect(Self.list(Self.block(lines, "PASSTHROUGH")) == CharsetTables.passthrough)
    #expect(Self.list(Self.block(lines, "UNRESOLVED")) == CharsetTables.unresolved)
    #expect(Self.list(Self.block(lines, "WORD_UNSUPPORTED")) == CharsetTables.wordUnsupported)
    #expect(Self.list(Self.block(lines, "WORD_PASSTHROUGH")) == CharsetTables.wordPassthrough)
  }
}

@Suite("multipart depth cap")
struct MultipartDepthTests {
  static func nested(_ depth: Int, leaf: String) -> [UInt8] {
    var s = "From: Synthetic <alerts@example.invalid>\r\nSubject: Nested\r\nMIME-Version: 1.0\r\n"
    s += "Content-Type: multipart/mixed; boundary=\"n-0-x\"\r\n\r\n"
    for i in 0..<(depth - 1) {
      s += "--n-\(i)-x\r\nContent-Type: multipart/mixed; boundary=\"n-\(i + 1)-x\"\r\n\r\n"
    }
    s += "--n-\(depth - 1)-x\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(leaf)\r\n--n-\(depth - 1)-x--"
    for i in (0..<(depth - 1)).reversed() { s += "\r\n--n-\(i)-x--" }
    s += "\r\n"
    return Array(s.utf8)
  }

  @Test("a message at the cap still reads its leaf")
  func atCap() throws {
    let r = try Normalizer.normalize(
      version: 1, raw: Self.nested(Normalizer.maxMultipartDepth, leaf: "deep leaf"), receivedAtMs: 0)
    #expect(r.text == "deep leaf" && r.partUsed == .plain)
  }

  @Test("one level past the cap is refused")
  func pastCap() {
    #expect(throws: NormalizeError.tooDeep) {
      try Normalizer.normalize(version: 1, raw: Self.nested(Normalizer.maxMultipartDepth + 1, leaf: "x"), receivedAtMs: 0)
    }
  }

  @Test("thousands of levels are refused without exhausting the stack")
  func veryDeep() {
    #expect(throws: NormalizeError.tooDeep) {
      try Normalizer.normalize(version: 1, raw: Self.nested(5000, leaf: "x"), receivedAtMs: 0)
    }
  }
}

@Suite("RFC 2047 scan is linear")
struct DecodeWordsLinearTests {
  static func scanEachWordToEnd(_ raw: [UInt8]) throws(MIMEFailure) -> String {
    let v = Array(MIME.trimExplicitBinary(raw[...]))
    if v.isEmpty { return "" }
    let marker: [UInt8] = [0x3d, 0x3f]
    guard let firstIdx = Bytes.index(of: marker, in: v) else { return NormText.decodeUTF8(v) }
    var out: [UInt8] = Array(v[0..<firstIdx])
    var base = firstIdx
    var betweenWords = false
    while true {
      guard let start = Bytes.index(of: marker, in: v, from: base) else { break }
      var cur = start + 2
      guard let q = Bytes.index(of: 0x3f, in: v, from: cur) else { break }
      let charset = Array(v[cur..<q])
      cur = q + 1
      if v.count < cur + 4 { break }
      let encoding = v[cur]
      cur += 1
      if v[cur] != 0x3f { break }
      cur += 1
      guard let j = Bytes.index(of: [0x3f, 0x3d], in: v, from: cur) else { break }
      let text = v[cur..<j]
      let content: [UInt8]?
      switch encoding {
      case 0x42, 0x62: content = MIME.bDecode(text)
      case 0x51, 0x71: content = MIME.qDecode(text)
      default: content = nil
      }
      guard let content else {
        betweenWords = false
        out.append(contentsOf: v[base..<(start + 2)])
        base = start + 2
        continue
      }
      if start > base && (!betweenWords || MIME.hasNonWhitespace(v[base..<start])) {
        out.append(contentsOf: v[base..<start])
      }
      if Bytes.latin1Lower(charset) == Bytes.of("utf-8") {
        out.append(contentsOf: content)
      } else {
        guard let converted = try MIME.convertWord(charset, content) else { return NormText.decodeUTF8(v) }
        out.append(contentsOf: converted.utf8)
      }
      base = j + 2
      betweenWords = true
    }
    out.append(contentsOf: v[base...])
    return NormText.decodeUTF8(out)
  }

  static func outcome(_ f: ([UInt8]) throws(MIMEFailure) -> String, _ raw: [UInt8]) -> String {
    do { return "ok:" + (try f(raw)) } catch { return "err:\(error)" }
  }

  @Test("random headers decode the same as a scan that searches from each word")
  func sameOutput() {
    let pieces = [
      "=?", "?=", "?", "=", "utf-8", "iso-8859-1", "x-nope", "B", "Q", "b", "q", "QUJD", "YQ==", "=41", "=E9", "_",
      " ", "\t", "a", "!", "\r\n",
    ]
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<20000 {
      var s = ""
      for _ in 0..<Int.random(in: 0...24, using: &rng) { s += pieces.randomElement(using: &rng)! }
      let raw = utf8(s)
      #expect(Self.outcome(MIME.decodeWords, raw) == Self.outcome(Self.scanEachWordToEnd, raw), "\(s)")
    }
  }

  @Test(
    "long headers of many encoded words decode fast",
    arguments: [
      "=?utf-8?Q?a?= ", "=?utf-8?X?", "=?utf-8?Q?=41", "=?utf-8?B?QUJD", "=?=?", "=?utf-8?B?", "=?a?b?c",
    ])
  func longHeader(_ unit: String) throws {
    var s = ""
    while s.utf8.count < 100_000 { s += unit }
    let raw = utf8(s + "?=")
    let elapsed = try ContinuousClock().measure { _ = try MIME.decodeWords(raw) }
    #expect(elapsed < .seconds(1), "\(unit) took \(elapsed)")
  }
}
