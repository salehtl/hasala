// Unit tests for CoreTemplate: the dialect's hand-written rule lists (a port of
// tmpl/dialect.test.ts, so a Go-side fixture edit cannot silently drop a row), the ICU
// translation's semantics where the probe corpus does not reach, the cost net over the shipping
// templates (tmpl/cost.test.ts) with ICU's time limit as the backstop, and the bundle.
import CorePrimitives
import CoreResources
import Foundation
import Testing

@testable import CoreTemplate

private func codes(_ p: String, _ flags: [String] = []) -> [Dialect.Reason] { Dialect.validate(p, flags: flags) }

private func match(_ p: String, _ text: String, ci: Bool = false) throws -> String? {
  let re = try ICUPattern.compile(p, caseInsensitive: ci)
  let u = Array(text.utf16)
  return try re.firstMatch(in: u).map { String(decoding: u[$0.range], as: UTF16.self) }
}

/// The repository root, found by walking up from this file.
private func repoRoot() -> URL {
  var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  while dir.path != "/" {
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("server/internal/tmpl/seed").path) { return dir }
    dir.deleteLastPathComponent()
  }
  return dir
}

@Suite("dialect rules (tmpl/dialect.test.ts)")
struct DialectRuleTests {
  @Test("the polynomial backtracking shapes are refused")
  func polynomial() {
    for p in [
      "[0-9]+[0-9]+z", "[0-9]+[0-9]+[0-9]+[0-9]+z", "[^\\n]+X[^\\n]+Y", "[^\\n]+X[^\\n]+Y[^\\n]+Z",
      "(?P<v>[0-9]+)[0-9]+z", "[0-9]{2,}[0-9]{3,}z", "(a+)(b+)", "(a+|b)c+",
    ] {
      #expect(codes(p).contains(.multipleUnboundedQuantifiers), "\(p)")
    }
  }

  @Test("one unbounded quantifier per branch, and every seed anchor, is still expressible")
  func oneUnbounded() {
    for p in [
      "[0-9]{2,}z", "[0-9]+z|[a-z]+q", "(a+|b+)c",
      "المبلغ\\n(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\\.[0-9]{2})", "الدفع الى\\n(?P<v>[^\\n]+)",
      "رقم البطاقة\\n(?P<v>[^ \\n]+)", "بتاريخ (?P<d>[0-9]{2}-[0-9]{2}-[0-9]{4})",
      "(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\\.[0-9]{2})[ \\t\\n\\f\\r]has been[ \\t\\n\\f\\r](?:withdrawn|debited|deducted)[ \\t\\n\\f\\r]from your account",
      "(?P<ccy>[A-Z]{3})(?P<amt>[0-9][0-9,]{0,24}\\.[0-9]{2})[ \\t\\n\\f\\r]has been[ \\t\\n\\f\\r](?:credited|deposited)[ \\t\\n\\f\\r](?:in)?to your account",
      "account ending with[ \\t\\n\\f\\r]+(?P<v>[0-9]{4})", "Debit Amount:\\n(?P<ccy>[A-Z]{3} ?)?(?P<amt>[0-9][0-9,]{0,24}\\.[0-9]{2})",
      "Transaction Date:\\n(?P<d>[^\\n]+)", "Beneficiary Name:\\n(?P<v>[^\\n]+)", "DEBIT$",
    ] {
      #expect(codes(p) == [], "\(p)")
    }
  }

  @Test("a variable-length repetition inside a repeated group is refused")
  func nestedVariable() {
    for p in [
      "(?:[a-z0-9 ]{1,8}){8}z", "(?:(?:[a-z]{1,4}){4}){4}z", "(?:[a-z0-9 ]{1,4}){8}z", "(?:a?){60}", "(?:a|aa){30}",
      "(?:a|){40}", "(?P<v>[0-9]{1,4}){2}", "(?:[0-9]{1,4}){2,4}", "(?:[0-9]{1,4}){0,2}", "(?:a{1,4}?){4}",
      "(?:(?:a|bcd)x){2}",
    ] {
      #expect(codes(p).contains(.nestedVariableRepetition), "\(p)")
    }
    for p in [
      "([0-9]{1,4})?", "([0-9]{1,4}){0,1}", "([0-9]{1,4}){1}", "(?:[a-z]{8}){8}", "[a-z]{1,64}", "(?:ab|cd){8}",
      "[0-9]{4,16}", "\\(a{1,4}\\){4}", "(?:[a{1,4}]x){4}",
    ] {
      #expect(codes(p) == [], "\(p)")
    }
  }

  @Test("the backtracking width of one branch is bounded; alternatives add, concatenation multiplies")
  func width() {
    for p in [
      "[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}z", "[0-9]{1,64}[0-9]{1,64}z",
      "[0-9]{1,25}[0-9]{1,41}z", "a?a?a?a?a?a?a?a?a?a?a?bz", "(?:a|bcd){20}", "x{0,24}x{0,24}|y{0,24}y{0,24}",
    ] {
      #expect(codes(p).contains(.repetitionWidthTooLarge), "\(p)")
    }
    for p in [
      "[0-9]{1,32}[0-9]{1,32}z", "[0-9]{1,25}[0-9]{1,40}z", "a?a?a?a?a?a?a?a?a?a?bz", "[0-9]{3,48}z",
      "(?P<ccy>[A-Z]{3} ?)?(?P<amt>[0-9][0-9,]{0,24}\\.[0-9]{2})[ \\t\\n\\f\\r]has been[ \\t\\n\\f\\r](?:credited|deposited)[ \\t\\n\\f\\r](?:in)?to your account",
      "x{0,24}x{0,19}|y{0,24}y{0,19}",
    ] {
      #expect(codes(p) == [], "\(p)")
    }
  }

  @Test("lengths are runes; offsets are runes; flags are checked")
  func runesAndFlags() {
    #expect(codes(String(repeating: "🏪", count: Dialect.maxPatternRunes)) == [])
    #expect(codes(String(repeating: "🏪", count: Dialect.maxPatternRunes + 1)) == [.patternTooLong])
    #expect(codes("المبلغ\\s") == [.escapePerlSpace])
    #expect(codes("a", ["i"]) == [])
    #expect(codes("a", ["g"]) == [.flagNotAllowed])
    #expect(codes("a", ["i", "i"]) == [.duplicateFlag])
  }

  @Test("a repetition count Go cannot hold is malformed; over Go's repeat limit is not compilable")
  func counts() {
    #expect(codes("a{99999999999999999999}") == [.malformedRepetition])
    #expect(codes("a{1000,}") == [])
    #expect(codes("a{1001,}") == [.notCompilable])
  }

  @Test("what JavaScript-u refuses to compile is not_compilable here too")
  func javascriptSyntax() {
    for p in ["a]", "a}", "[z-a]", "[\\d-z]", "[a-\\w]", "[a--b]"] {
      #expect(codes(p) == [.notCompilable], "\(p)")
    }
    for p in ["[a-b-c]", "[--a]", "[a-]", "[-a]", "a|", "()", "(?:)"] {
      #expect(codes(p) == [], "\(p)")
    }
  }
}

@Suite("ICU translation semantics")
struct EngineTests {
  @Test("$ is the end of input only, and ^ the start only")
  func anchors() throws {
    #expect(try match("abc$", "abc\n") == nil)
    #expect(try match("abc$", "abc") == "abc")
    #expect(try match("^b", "a\nb") == nil)
    #expect(try match("DEBIT$", "x DEBIT", ci: true) == "DEBIT")
  }

  @Test("\\d and \\w are ASCII; [0-9] never matches Arabic-Indic digits")
  func asciiClasses() throws {
    #expect(try match("\\d", "٢") == nil)
    #expect(try match("[0-9]", "٢٥") == nil)
    #expect(try match("\\w", "é") == nil)
    #expect(try match("\\W", "é") == "é")
    #expect(try match("\\D+", "ab12") == "ab")
  }

  @Test("case-insensitive matching is SIMPLE folding, as in Go and JavaScript-iu")
  func simpleFolding() throws {
    #expect(try match("k", "\u{212A}", ci: true) == "\u{212A}")
    #expect(try match("s", "\u{17F}", ci: true) == "\u{17F}")
    #expect(try match("[a-z]", "\u{212A}", ci: true) == "\u{212A}")
    #expect(try match("\\w", "\u{17F}", ci: true) == "\u{17F}")
    #expect(try match("\\w", "\u{17F}") == nil)
    #expect(try match("[^a-z]", "\u{212A}", ci: true) == nil)
    #expect(try match("\\W", "K", ci: true) == nil)
    // Full folding would match these; Go and JavaScript do not.
    #expect(try match("ss", "ß", ci: true) == nil)
    #expect(try match("fi", "\u{FB01}", ci: true) == nil)
    #expect(try match("aed", "AED", ci: true) == "AED")
  }

  /// Two places where the JavaScript twin's engine is the odd one out, pinned to Go's answer
  /// (measured 2026-10-11 against Go's regexp and Bun): a capture inside a group repeated more
  /// than once keeps its last participating value in Go and ICU, while JavaScript resets it on
  /// every iteration; and `[a-z]` under `i` matches U+212A in Go, V8 and WebKit (and here), but
  /// not in Bun's JavaScriptCore (tmpl/agreement.test.ts pins that as a Bun bug); and Bun
  /// 1.3.13 finds no match for `(?:^b)?A` in "c A", where Go, V8 and ICU match "A" at 2 (also
  /// pinned there). The dialect accepts the first and last shapes; no shipping template uses
  /// either.
  @Test("where JavaScript and Go disagree on an accepted pattern, ICU answers as Go does")
  func goSemantics() throws {
    let re = try ICUPattern.compile("(?:(?P<v>a)|b){2}", caseInsensitive: false)
    #expect(Dialect.validatePattern("(?:(?P<v>a)|b){2}", flags: []) == [])
    let u = Array("ab".utf16)
    let m = try #require(try re.firstMatch(in: u))
    #expect(m.groups[0] == 0..<1)  // Go: [0 2 0 1]; JavaScript: v undefined
    #expect(try match("[a-z]", "\u{212A}", ci: true) == "\u{212A}")
    #expect(Dialect.validatePattern("(?:^b)?A", flags: []) == [])
    let anchored = try ICUPattern.compile("(?:^b)?A", caseInsensitive: false)
    let text = Array("c A".utf16)
    #expect(try anchored.firstMatch(in: text)?.range == 2..<3)  // Go: [2 3]; Bun: no match
  }

  @Test("ICU set operators and nested sets have no meaning in a translated pattern")
  func setSyntax() throws {
    #expect(try match("[a&&b]", "&") == "&")
    #expect(try match("[a&&b]", "b") == "b")
    #expect(try match("[\\^x]", "^") == "^")
  }

  @Test("named groups (underscores included) map to ICU's numbered groups; absent and empty differ")
  func groups() throws {
    let re = try ICUPattern.compile("(?P<a_b>x)?(y)(?P<c>z*)", caseInsensitive: false)
    #expect(re.groups == ["a_b", nil, "c"])
    let u = Array("y".utf16)
    let m = try #require(try re.firstMatch(in: u))
    #expect(m.groups[0] == nil)
    #expect(m.groups[1] == 0..<1)
    #expect(m.groups[2] == 1..<1)
  }

  @Test("empty and full classes compile; an empty text is searchable")
  func edges() throws {
    #expect(try match("[^\\d\\D]", "abc") == nil)
    #expect(try match("[\\d\\D]", "\u{10FFFF}") == "\u{10FFFF}")
    #expect(try match("a?", "") == "")
    #expect(try match("🏪+", "x🏪🏪y") == "🏪🏪")
  }

  @Test("ICU's time limit stops a dialect-accepted pattern that is pathological in a backtracking engine")
  func timeLimit() throws {
    let re = try ICUPattern.compile("[0-9]{1,32}[0-9]{1,32}z", caseInsensitive: false)
    let body = Array(String(repeating: "1", count: 1_000_000).utf16)
    let start = ContinuousClock.now
    #expect(throws: EngineError.limitExceeded) { try re.firstMatch(in: body) }
    #expect(ContinuousClock.now - start < .seconds(10))
  }

  @Test("one compiled pattern serves concurrent callers")
  func concurrency() async throws {
    let re = try ICUPattern.compile("(?P<v>[0-9]{4})$", caseInsensitive: false)
    try await withThrowingTaskGroup(of: Bool.self) { group in
      for i in 0..<64 {
        group.addTask {
          let s = "card \(1000 + i)"
          let u = Array(s.utf16)
          let m = try re.firstMatch(in: u)
          return m.flatMap { $0.groups[0] }.map { String(decoding: u[$0], as: UTF16.self) } == String(1000 + i)
        }
      }
      for try await ok in group { #expect(ok) }
    }
  }
}

@Suite("executor")
struct ExecutorTests {
  static func definition(_ extra: String = "", required: String = "[\"amount\"]") -> [UInt8] {
    Array(
      """
      {"id":"t.v1","version":1,"bank":"t","normalizer_version":1,"match":{"sender_domain":["t.example"]},
       "default_currency":"AED","date_from":"email","required":\(required),
       "extract":[{"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[0-9][0-9,]{0,24}\\\\.[0-9]{2})"]}\(extra)]}
      """.utf8)
  }

  @Test("bounds refuse, never truncate")
  func bounds() throws {
    let t = try CompiledTemplate(json: Self.definition())
    #expect(try t.execute(subject: "", normalizedBody: "Amt: 1.00").matched)
    let big = "Amt: 1.00 " + String(repeating: "x", count: TemplateBounds.maxBodyBytes)
    #expect(try t.execute(subject: "", normalizedBody: big).error == .tooLarge)
    let subj = String(repeating: "x", count: TemplateBounds.maxSubjectBytes + 1)
    #expect(try t.execute(subject: subj, normalizedBody: "Amt: 1.00").error == .tooLarge)
  }

  @Test("a match the time limit stops is refused as too_large, not reported as no match")
  func limitIsTooLarge() throws {
    let def = Array(
      """
      {"id":"t.v1","version":1,"bank":"t","normalizer_version":1,"match":{"sender_domain":["t.example"]},
       "default_currency":"AED","date_from":"email","required":["merchant"],
       "extract":[{"field":"merchant","type":"text","source":"body","patterns":["(?P<v>[0-9]{1,32}[0-9]{1,32})z"]}]}
      """.utf8)
    let t = try CompiledTemplate(json: def)
    let r = try t.execute(subject: "", normalizedBody: String(repeating: "1", count: 1_000_000))
    #expect(r.error == .tooLarge)
    #expect(!r.matched)
  }

  @Test("a cancelled task stops before the next pattern search and records no verdict")
  func cancellation() async throws {
    let t = try CompiledTemplate(json: Self.definition())
    let task = Task { () -> TemplateError? in
      withUnsafeCurrentTask { $0?.cancel() }
      do throws(TemplateError) {
        _ = try t.execute(subject: "", normalizedBody: "Amt: 1.00")
        return nil
      } catch {
        return error
      }
    }
    #expect(await task.value == .cancelled)
    // The same body outside a cancelled task matches.
    #expect(try t.execute(subject: "", normalizedBody: "Amt: 1.00").matched)
  }

  @Test("load-time refusals: dialect, unknown fields, impossible requirements")
  func refusals() throws {
    let bad = Array(
      """
      {"id":"t.v1","version":1,"bank":"t","normalizer_version":1,"match":{"sender_domain":["t"]},
       "default_currency":"AED","date_from":"email","required":["amount"],
       "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>.+)"]}]}
      """.utf8)
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: bad) }
    do throws(TemplateError) {
      _ = try CompiledTemplate(json: bad)
    } catch .dialect(_, let c) {
      #expect(c == ["bare_dot"])
    } catch {
      Issue.record("expected a dialect error, got \(error)")
    }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.definition(required: "[\"toString\"]")) }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Self.definition(required: "[\"is_transfer\"]")) }
    #expect(throws: TemplateError.self) { try CompiledTemplate(json: Array("{\"version\":\"1\"}".utf8)) }
  }

  @Test("amounts: commas, exactly two decimals, Int64 bound, currency override")
  func amounts() {
    #expect(CompiledTemplate.convertAmount("12,750.00", nil, "AED")! == (1_275_000, "AED"))
    #expect(CompiledTemplate.convertAmount(" 1.00\u{0B}", "usd ", "AED")! == (100, "USD"))
    #expect(CompiledTemplate.convertAmount("1.0", nil, "AED") == nil)
    #expect(CompiledTemplate.convertAmount("1", nil, "AED") == nil)
    #expect(CompiledTemplate.convertAmount("-1.00", nil, "AED") == nil)
    #expect(CompiledTemplate.convertAmount("92233720368547758.07", nil, "AED")! == (Int64.max, "AED"))
    #expect(CompiledTemplate.convertAmount("92233720368547758.08", nil, "AED") == nil)
    #expect(CompiledTemplate.convertAmount("1.00", "ß", "AED") == nil)
    #expect(CompiledTemplate.convertAmount("1.00\u{A0}", nil, "AED") == nil)  // NBSP is not in the cutset
  }

  @Test("dates: three layouts, fixed widths, ASCII month folding, upper-case AM/PM, first-token retry")
  func dates() {
    #expect(CompiledTemplate.convertDate("05-06-2026", ["DD-MM-YYYY"]) == "2026-06-05T00:00:00Z")
    #expect(CompiledTemplate.convertDate("15/mar/2026 09:15 PM", ["DD/Mon/YYYY hh:mm A"]) == "2026-03-15T21:15:00Z")
    #expect(CompiledTemplate.convertDate("15/Mar/2026 12:05 AM", ["DD/Mon/YYYY hh:mm A"]) == "2026-03-15T00:05:00Z")
    #expect(CompiledTemplate.convertDate("15/Mar/2026 09:15 pm", ["DD/Mon/YYYY hh:mm A"]) == nil)
    #expect(CompiledTemplate.convertDate("15/Mar/2026 09:15 pm", ["DD/Mon/YYYY hh:mm A", "DD/Mon/YYYY"]) == "2026-03-15T00:00:00Z")
    #expect(CompiledTemplate.convertDate("5/Jun/2026", ["DD/Mon/YYYY"]) == nil)
    #expect(CompiledTemplate.convertDate("31-02-2026", ["DD-MM-YYYY"]) == nil)
    #expect(CompiledTemplate.convertDate("29-02-2024", ["DD-MM-YYYY"]) == "2024-02-29T00:00:00Z")
    #expect(CompiledTemplate.convertDate("15/Mar/2026 13:25 PM", ["DD/Mon/YYYY hh:mm A"]) == nil)
    #expect(CompiledTemplate.convertDate("05-06-26", ["DD-MM-YYYY"]) == nil)
  }

  @Test("last4 keeps the last four ASCII digits; Arabic-Indic digits are not digits")
  func last4() {
    #expect(CompiledTemplate.convertLast4("XXXX1234") == "1234")
    #expect(CompiledTemplate.convertLast4("12-34-56") == "3456")
    #expect(CompiledTemplate.convertLast4("٢٣٤٥") == nil)
    #expect(CompiledTemplate.convertLast4("7") == "7")
  }
}

@Suite("bundled templates")
struct BundledTemplateTests {
  @Test("the bundle loads every seed template, and they are the server's seed byte for byte")
  func bundle() throws {
    let r = BundledTemplates.load()
    #expect(r.skipped == [])
    #expect(
      r.templates.map(\.definition.id) == [
        "adib.account.v1", "adib.alert.v1", "dib.account.v1", "dib.card.v1", "dib.money-transfer.v1", "dib.transfer.v1",
        "enbd.alert.v1", "enbd.transfer.v1",
      ])
    let seed = repoRoot().appendingPathComponent("server/internal/tmpl/seed")
    let seedFiles = try FileManager.default.contentsOfDirectory(atPath: seed.path).filter { $0.hasSuffix(".json") }.sorted()
    #expect(seedFiles == TemplatesManifest.entries.map(\.file))
    for e in TemplatesManifest.entries {
      let bundled = try Data(contentsOf: try #require(CoreResources.bundle.url(forResource: e.file, withExtension: nil, subdirectory: "templates")))
      #expect(bundled == (try Data(contentsOf: seed.appendingPathComponent(e.file))), "\(e.file) differs from the seed")
      #expect(Hex.encode(sha256(bundled)) == e.sha256)
    }
  }

  @Test("a tampered or broken template is skipped and named; the others still load")
  func skips() throws {
    let good = TemplatesManifest.entries[0]
    let entries = [
      good,
      TemplatesManifest.Entry(file: "x.json", id: "x", version: 1, sha256: String(repeating: "0", count: 64)),
      TemplatesManifest.Entry(file: "missing.json", id: "missing", version: 1, sha256: ""),
    ]
    let r = BundledTemplates.load(entries: entries) { f in
      if f == "missing.json" { return nil }
      return CoreResources.bundle.url(forResource: good.file, withExtension: nil, subdirectory: "templates")
        .flatMap { try? Data(contentsOf: $0) }
    }
    #expect(r.templates.count == 1)
    let want = [
      BundledTemplates.Skipped(id: "x", reason: "sha256"), BundledTemplates.Skipped(id: "missing", reason: "missing"),
    ]
    #expect(r.skipped == want)
  }

  /// tmpl/cost.test.ts: bodies chosen to be the WORST case for each anchor shape. Every
  /// shipping template must finish without being stopped, well inside the budget.
  @Test("no hostile body is super-linear against a shipping template, and none trips the time limit")
  func cost() throws {
    let n = 200_000
    func rep(_ s: String, _ k: Int) -> String { String(repeating: s, count: k) }
    let hostile: [(String, String)] = [
      ("digits and commas", rep("1,", n / 2)), ("digits after a currency word", "AED " + rep("1,", n / 2)),
      ("one enormous line", rep("x", n)), ("zeros then a decimal point", rep("0", n) + ".00"),
      ("the DIB amount anchor then a run", "المبلغ\n" + rep("1,", n / 2)),
      ("the DIB amount anchor repeated", rep("المبلغ\n1,", n / 20)),
      ("the DIB merchant anchor repeated", rep("الدفع الى\n", n / 20)),
      ("the ENBD verb, never completed", rep("AED 1.00 has been ", n / 40)), ("newlines only", rep("\n", n)),
      ("a near-miss subject line", rep("account ending with ", n / 40)),
    ]
    let subject = "Transaction advice for your account ending with 8642"
    let hostileSubject = rep("account ending with ", 3_000)
    for t in BundledTemplates.load().templates {
      var runs = hostile.map { ($0.0, subject, $0.1) }
      runs.append(("a hostile subject", hostileSubject, "AED 1.00"))
      for (name, s, b) in runs {
        #expect(b.utf8.count < TemplateBounds.maxBodyBytes && s.utf8.count < TemplateBounds.maxSubjectBytes)
        let start = ContinuousClock.now
        let got = try t.execute(subject: s, normalizedBody: b)
        let took = ContinuousClock.now - start
        #expect(got.error != .tooLarge, "\(t.definition.id) on \(name): stopped by the time limit")
        #expect(took < .seconds(2), "\(t.definition.id) took \(took) on \(name)")
      }
    }
  }

  @Test("every bundled amount anchor has a bounded digit run")
  func boundedAmounts() {
    var checked = 0
    for t in BundledTemplates.load().templates {
      for x in t.definition.extract where x.type == "amount" {
        for p in x.patterns {
          #expect(!p.contains("[0-9,]*"), "\(t.definition.id): \(p)")
          checked += 1
        }
      }
    }
    #expect(checked > 5)
  }
}
