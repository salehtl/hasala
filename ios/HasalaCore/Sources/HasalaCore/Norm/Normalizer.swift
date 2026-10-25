// CoreNorm (Norm/), spec 04 §2.2: the v2 normalizer, a byte-level port of
// the ledgerd TypeScript client's src/norm (itself the twin of the Go normalizer, contract
// v2-normalizer-v1 in the ledgerd design archive). Raw RFC 822 bytes (Gmail `format=raw`,
// base64url-decoded) in; the normalized text a template matches against out.
//
// The output must be BYTE-IDENTICAL to Go's and TypeScript's for the same input, because a
// template match made here and one made by the oracle have to be the same match. The fixtures
// in conformance/normalizer (and the real-corpus set in the private fixtures checkout) pin
// that; HasalaCoreConformanceTests runs them.
//
// Every decision that could differ between platforms is pinned rather than left to a default:
// the trim sets are written out, charsets come from tables generated from Go's registry
// (CharsetTables.swift), entity decoding is one left-to-right pass, forward dates are matched
// against four closed layouts, and all text work is on bytes or scalars, never `Character`.
//
// `subject` and `from` are CONTENT, not identity: for an inline forward they come out of the
// body. Trust is CoreMail's Authentication-Results verdict and nothing from this module.
import CoreTime
import HasalaText

/// Which part the text came from.
public enum PartUsed: String, Sendable, Equatable {
  case html, plain, raw
}

/// Where `emailDate` came from.
public enum DateSource: String, Sendable, Equatable {
  case forwardHeader = "forward_header"
  case received
}

public struct NormalizeResult: Sendable, Equatable {
  /// The normalized, unwrapped body templates match against.
  public let text: String
  public let partUsed: PartUsed
  /// The chosen leaf's DECLARED charset, trimmed and lower-cased; empty when none.
  public let charset: String
  /// EFFECTIVE subject (the inner one when forwarded). Content, never identity.
  public let subject: String
  /// EFFECTIVE From (the inner one when forwarded). Content, never identity.
  public let from: String
  /// A forward MARKER line was found (not that inner headers were recovered).
  public let forwarded: Bool
  /// RFC 3339 UTC, whole seconds: the inner forwarded Date (naive, read as UTC) when it
  /// parses, else the received time.
  public let emailDate: String
  public let dateSource: DateSource
}

public enum NormalizeError: Error, Equatable, Sendable {
  /// A version this build cannot run.
  case unknownVersion(Int)
  /// A well-formed message with neither a text/html nor a text/plain leaf.
  case noTextPart
  /// A charset Go decodes with a codec no other executor reproduces (UTF-16, Shift_JIS, GB*,
  /// ISO-2022-*). Refused rather than guessed; the caller routes the message to review.
  case unsupportedCharset(String)
  case tooDeep
}

public enum Normalizer {
  /// The newest normalizer algorithm.
  public static let currentVersion = 1

  /// Every version this build can run, oldest first. Old versions are never removed.
  public static func versions() -> [Int] { [1] }

  public static let maxMultipartDepth = 32

  /// Runs normalizer `version` over a raw RFC 822 message. `receivedAtMs` is the mailbox
  /// arrival time (Gmail `internalDate`, epoch milliseconds), used as `emailDate` whenever no
  /// inner forwarded Date is recoverable.
  public static func normalize(
    version: Int, raw: [UInt8], receivedAtMs: Int64
  ) throws(NormalizeError) -> NormalizeResult {
    guard version == currentVersion else { throw .unknownVersion(version) }
    let extracted: Extracted?
    do throws(MIMEFailure) {
      extracted = try extract(raw)
    } catch .unsupportedCharset(let label) {
      throw .unsupportedCharset(label)
    } catch .tooDeep {
      throw .tooDeep
    } catch {
      // extract lets only .unsupportedCharset escape; anything else is a bug, and failing
      // closed (no text) is the safe reading of it.
      throw .noTextPart
    }
    guard let ex = extracted else { throw .noTextPart }

    // Stages 5-9. Only an HTML leaf is stripped; a text/plain leaf and the raw fallback reach
    // the entity decoder as they are, exactly as v1 does.
    let body = ex.part == .html ? stripHTML(NormText.scalars(ex.body)) : NormText.scalars(ex.body)
    let text = collapse(body)

    // Stage 10.
    let fwd = Unwrap.unwrapForward(from: ex.from, subject: ex.subject, body: text)
    let (emailDate, dateSource) = emailDateOf(forwardDate: fwd.date, receivedAtMs: receivedAtMs)
    return NormalizeResult(
      text: fwd.body, partUsed: ex.part, charset: ex.charset, subject: fwd.subject, from: fwd.from,
      forwarded: fwd.found, emailDate: emailDate, dateSource: dateSource)
  }

  static func emailDateOf(forwardDate: String, receivedAtMs: Int64) -> (String, DateSource) {
    if !forwardDate.isEmpty, let parsed = Unwrap.parseForwardDate(forwardDate) {
      return (format(parsed), .forwardHeader)
    }
    return (format(epochMs: receivedAtMs), .received)
  }

  // MARK: - Stages 1-4

  struct Extracted {
    let body: String
    let part: PartUsed
    let charset: String
    let subject: String
    let from: String
  }

  /// Collects the first non-empty text/html and text/plain leaves, depth first.
  struct Walker {
    var html = ""
    var plain = ""
    var htmlCharset = ""
    var plainCharset = ""

    /// Returns whether the walk was aborted. Throws only `.unsupportedCharset` and `.tooDeep`.
    mutating func walk(_ e: MIME.Entity, depth: Int = 0) throws(MIMEFailure) -> Bool {
      if MIME.hasPrefix(e.mediaType, "multipart/") {
        if depth >= Normalizer.maxMultipartDepth { throw .tooDeep }
        do throws(MIMEFailure) {
          var parts = try MIME.Multipart(body: e.rawBody, boundary: e.params["boundary"] ?? "")
          while let part = try parts.next() {
            let entity = try MIME.newEntity(part.header, part.rawBody)
            // Go surfaces an unknown charset or encoding on a SUB-PART as an error out of
            // NextPart, which aborts the walk; on the top-level entity it is ignored.
            if entity.failed { return true }
            if try walk(entity, depth: depth + 1) { return true }
          }
        } catch .walkAbort {
          return true
        } catch .parse {
          return true
        }
        return false
      }

      let isHTML = e.mediaType == Bytes.of("text/html")
      guard isHTML || e.mediaType == Bytes.of("text/plain") else { return false }
      let text: String
      do throws(MIMEFailure) {
        text = try e.text()
      } catch .unsupportedCharset(let label) {
        throw .unsupportedCharset(label)
      } catch {
        // An undecodable leaf (bad base64, an invalid quoted-printable byte) is SKIPPED, not
        // fatal, and its partial bytes are discarded.
        return false
      }
      let cs = NormText.jsLower(NormText.trimExplicit(e.params["charset"] ?? ""))
      if isHTML {
        if html.isEmpty {
          html = text
          htmlCharset = cs
        }
      } else if plain.isEmpty {
        plain = text
        plainCharset = cs
      }
      return false
    }
  }

  /// Stages 1-4; nil when a well-formed message has no text leaf. Throws only
  /// `.unsupportedCharset` and `.tooDeep`.
  static func extract(_ raw: [UInt8]) throws(MIMEFailure) -> Extracted? {
    let header: ParsedHeader
    do {
      header = try MIME.readHeader(raw[...], 0)
    } catch {
      // Stage 1: an unrecoverable header. v2 falls back to the raw body rather than dropping.
      return try rawFallback(raw)
    }

    let subject = try MIME.decodeWords(header.get("subject"))
    let from = MIME.bareAddress(try MIME.decodeWords(header.get("from")))

    let entity = try MIME.newEntity(header, raw[header.bodyStart...])
    var walker = Walker()
    let aborted = try walker.walk(entity)

    if !walker.html.isEmpty {
      return Extracted(body: walker.html, part: .html, charset: walker.htmlCharset, subject: subject, from: from)
    }
    if !walker.plain.isEmpty {
      return Extracted(body: walker.plain, part: .plain, charset: walker.plainCharset, subject: subject, from: from)
    }
    // The tree broke apart before any text leaf was reached: record the raw body.
    if aborted { return try rawFallback(raw) }
    return nil
  }

  static func rawFallback(_ raw: [UInt8]) throws(MIMEFailure) -> Extracted {
    let (subject, from) = try scanRawHeaders(raw)
    return Extracted(
      body: NormText.decodeUTF8(MIME.rawBodyAfterHeaders(raw)), part: .raw, charset: "", subject: subject, from: from)
  }

  /// Subject and From of a message whose header did not parse (the raw-fallback path only).
  /// A continuation line joins its predecessor with one U+0020 after trimming.
  static func scanRawHeaders(_ raw: [UInt8]) throws(MIMEFailure) -> (String, String) {
    let body = MIME.rawBodyAfterHeaders(raw)
    let headLen = body.count < raw.count ? raw.count - body.count : raw.count
    // `replaceAll("\r\n", "\n")` then `split("\n")`.
    var s: [UInt8] = []
    s.reserveCapacity(headLen)
    var k = 0
    while k < headLen {
      if raw[k] == Bytes.cr && k + 1 < headLen && raw[k + 1] == Bytes.lf {
        s.append(Bytes.lf)
        k += 2
      } else {
        s.append(raw[k])
        k += 1
      }
    }
    var fields: [[UInt8]] = []
    var start = 0
    func line(_ l: ArraySlice<UInt8>) {
      if l.isEmpty { return }
      if (l.first == Bytes.sp || l.first == Bytes.tab) && !fields.isEmpty {
        fields[fields.count - 1].append(Bytes.sp)
        fields[fields.count - 1].append(contentsOf: MIME.trimExplicitBinary(l))
        return
      }
      fields.append(Array(l))
    }
    for i in 0..<s.count where s[i] == Bytes.lf {
      line(s[start..<i])
      start = i + 1
    }
    line(s[start..<s.count])

    var subject = ""
    var from = ""
    for f in fields {
      guard let i = Bytes.index(of: 0x3a, in: f) else { continue }
      let name = Bytes.latin1Lower(Array(MIME.trimExplicitBinary(f[0..<i])))
      let value = Array(f[(i + 1)...])
      if name == Bytes.of("subject") && subject.isEmpty {
        subject = try MIME.decodeWords(value)
      } else if name == Bytes.of("from") && from.isEmpty {
        from = MIME.bareAddress(try MIME.decodeWords(value))
      }
    }
    return (subject, from)
  }

  // MARK: - Stages 5-9

  typealias Scalars = [Unicode.Scalar]

  /// Whether `s[i...]` starts with the ASCII `word` (lower case), case-insensitively as Go's
  /// `(?i)` compares it (`Unwrap.foldCI`: ASCII, plus U+017F as `s` and U+212A as `k`).
  static func hasCI(_ s: Scalars, _ i: Int, _ word: Scalars) -> Bool {
    guard i + word.count <= s.count else { return false }
    for k in 0..<word.count where Unwrap.foldCI(s[i + k]) != word[k] { return false }
    return true
  }

  static func has(_ s: Scalars, _ i: Int, _ word: Scalars) -> Bool {
    guard i + word.count <= s.count else { return false }
    for k in 0..<word.count where s[i + k] != word[k] { return false }
    return true
  }

  /// The first index `>= from` holding `c`, for queries whose `from` never decreases: a
  /// moving pointer, so a body full of unclosed `<` stays linear rather than quadratic.
  struct ForwardScan {
    let s: Scalars
    let c: Unicode.Scalar
    var ptr = 0
    mutating func next(from: Int) -> Int? {
      if ptr < from { ptr = from }
      while ptr < s.count && s[ptr] != c { ptr += 1 }
      return ptr < s.count ? ptr : nil
    }
  }

  /// `s.replace(/<tag[^>]*>.*?<\/tag>/gisu, " ")`: at each position, `<tag` (case-insensitive
  /// as in `hasCI`), then everything up to the first `>`, then the shortest run up to the
  /// first `</tag>`.
  static func removeElement(_ s: Scalars, _ tag: String) -> Scalars {
    let open = Array(("<" + tag).unicodeScalars)
    let close = Array(("</" + tag + ">").unicodeScalars)
    // Every start of `</tag>` (case-insensitive), ascending; queried with a moving pointer.
    var closes: [Int] = []
    var k = 0
    while k + close.count <= s.count {
      if s[k] == "<" && hasCI(s, k, close) { closes.append(k) }
      k += 1
    }
    var closePtr = 0
    var gts = ForwardScan(s: s, c: ">")
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == "<", hasCI(s, i, open), let gt = gts.next(from: i + open.count) {
        while closePtr < closes.count && closes[closePtr] < gt + 1 { closePtr += 1 }
        if closePtr < closes.count {
          out.append(" ")
          i = closes[closePtr] + close.count
          continue
        }
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  /// `s.replaceAll(literal, "\n")`, case-sensitive.
  static func replaceAll(_ s: Scalars, _ literal: String) -> Scalars {
    let w = Array(literal.unicodeScalars)
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == w[0] && has(s, i, w) {
        out.append("\n")
        i += w.count
        continue
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  /// The five closing/void tags that become a newline BEFORE the generic tag rule: exactly
  /// v1's list, case-sensitive.
  static let blockTags = ["<br>", "<br/>", "</p>", "</tr>", "</div>"]

  static func stripHTML(_ input: Scalars) -> Scalars {
    var s = removeElement(input, "script")
    s = removeElement(s, "style")
    for t in blockTags { s = replaceAll(s, t) }
    // `/<[^>]+>/gs` -> "\n".
    var gts = ForwardScan(s: s, c: ">")
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == "<", i + 1 < s.count, s[i + 1] != ">", let gt = gts.next(from: i + 1) {
        out.append("\n")
        i = gt + 1
        continue
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  /// Exactly six entities, decoded in ONE left-to-right pass that never rescans its own output
  /// (`&amp;lt;` is `&lt;`, not `<`).
  static let entities: [(Scalars, Unicode.Scalar)] = [
    (Array("&nbsp;".unicodeScalars), " "),
    (Array("&amp;".unicodeScalars), "&"),
    (Array("&lt;".unicodeScalars), "<"),
    (Array("&gt;".unicodeScalars), ">"),
    (Array("&quot;".unicodeScalars), "\""),
    (Array("&#39;".unicodeScalars), "'"),
  ]

  /// Stages 6-9: entities, whitespace runs (U+0020, U+0009, U+00A0) to one space, per-line
  /// explicit trim, empty lines dropped, joined with `\n`.
  static func collapse(_ s: Scalars) -> String {
    var decoded: Scalars = []
    decoded.reserveCapacity(s.count)
    var i = 0
    outer: while i < s.count {
      let c = s[i]
      if c == "&" {
        for (e, r) in entities where has(s, i, e) {
          decoded.append(r)
          i += e.count
          continue outer
        }
      }
      decoded.append(c)
      i += 1
    }

    // A scalar array, not String.UnicodeScalarView: appending to the view re-checks the
    // string's tail each time, which made this quadratic on bodies of many short lines.
    var out: Scalars = []
    out.reserveCapacity(decoded.count)
    var line: Scalars = []
    func flush() {
      let t = line.trimming(.unwrapTrim)
      if !t.isEmpty {
        if !out.isEmpty { out.append("\n") }
        out.append(contentsOf: t)
      }
      line.removeAll(keepingCapacity: true)
    }
    var inSpace = false
    for c in decoded {
      if c == "\n" {
        flush()
        inSpace = false
        continue
      }
      if c == " " || c == "\t" || c == "\u{A0}" {
        if !inSpace { line.append(" ") }
        inSpace = true
        continue
      }
      inSpace = false
      line.append(c)
    }
    flush()
    return NormText.string(out)
  }

  // MARK: - Dates

  /// RFC 3339 UTC with no fractional seconds (Go's time.RFC3339 for a UTC time).
  static func format(_ d: Unwrap.NaiveDateTime) -> String {
    let date = "\(Civil.pad(d.year, 4))-\(Civil.pad(d.month, 2))-\(Civil.pad(d.day, 2))"
    return "\(date)T\(Civil.pad(d.hour, 2)):\(Civil.pad(d.minute, 2)):\(Civil.pad(d.second, 2))Z"
  }

  static func format(epochMs: Int64) -> String {
    let days = Civil.floorDiv(epochMs, Civil.msPerDay)
    let (y, m, d) = Civil.civilFromDays(days)
    let rem = epochMs - days * Civil.msPerDay
    return format(
      Unwrap.NaiveDateTime(
        year: Int(y), month: m, day: d, hour: Int(rem / 3_600_000), minute: Int(rem / 60_000 % 60),
        second: Int(rem / 1000 % 60)))
  }
}
