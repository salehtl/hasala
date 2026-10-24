// The MIME subset the normalizer contract needs: a byte-level port of norm/mime.ts, itself a
// port of what the Go normalizer does (go-message/textproto, mime.ParseMediaType,
// mime/quotedprintable, strict base64, mime.WordDecoder, the address cascade and the multipart
// reader). Go's leniencies are reproduced, and so is WHICH error is raised where, because the
// error class decides between "skip this leaf", "abort the walk" and "fall back to the raw body".
//
// Header values are BYTES throughout (the twin's "binary strings"), exactly as Go strings are;
// they become text only in `decodeWords`.
import HasalaText

/// The failure classes of the MIME walk (mime.ts's error classes).
enum MIMEFailure: Error, Equatable {
  /// The header block could not be parsed: the stage-1 raw-body fallback.
  case parse
  case tooDeep
  /// A sub-part could not be produced: aborts the walk (anything collected stands).
  case walkAbort
  /// A leaf's body could not be decoded: the leaf is skipped.
  case leafDecode
  /// A charset Go decodes with a codec no other executor mirrors: refused, never guessed.
  case unsupportedCharset(String)
}

// MARK: - Header parsing (go-message/textproto.ReadHeader)

struct HeaderField {
  /// ASCII-lower-cased field name.
  let key: [UInt8]
  /// The unfolded value, bytes.
  let value: [UInt8]
}

struct ParsedHeader {
  var fields: [HeaderField]
  /// Offset of the first body byte, just past the blank line.
  var bodyStart: Int

  /// go-message's `Header.Get`: the first field with this (ASCII) name, or empty.
  func get(_ name: StaticString) -> [UInt8] {
    let want = Bytes.of(name)
    for f in fields where f.key == want { return f.value }
    return []
  }
}

enum MIME {
  static func isSpaceByte(_ b: UInt8) -> Bool { b == Bytes.sp || b == Bytes.tab }

  /// bufio.ReadLine: the line WITHOUT its terminator (`\n`, and one `\r` before it). `eof` only
  /// when nothing is left; a final line with no newline is a normal line.
  static func readLine(_ buf: ArraySlice<UInt8>, _ pos: Int) -> (start: Int, end: Int, next: Int, eof: Bool) {
    if pos >= buf.endIndex { return (pos, pos, pos, true) }
    guard let nl = Bytes.index(of: Bytes.lf, in: buf, from: pos) else {
      return (pos, buf.endIndex, buf.endIndex, false)
    }
    var end = nl
    if end > pos && buf[end - 1] == Bytes.cr { end -= 1 }
    return (pos, end, nl + 1, false)
  }

  /// go-message's `trim`: spaces and tabs only.
  static func trimSpaceTab(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> { Bytes.trim(s, where: isSpaceByte) }

  /// go-message's trimAroundNewlines: unfold, joining the non-empty segments with one space.
  static func trimAroundNewlines(_ v: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    var segStart = v.startIndex
    var i = v.startIndex
    func segment(_ lo: Int, _ hi: Int) {
      var l = v[lo..<hi]
      if l.last == Bytes.cr { l = l.dropLast() }
      l = trimSpaceTab(l)
      if l.isEmpty { return }
      if !out.isEmpty { out.append(Bytes.sp) }
      out.append(contentsOf: l)
    }
    while i < v.endIndex {
      if v[i] == Bytes.lf {
        segment(segStart, i)
        segStart = i + 1
      }
      i += 1
    }
    segment(segStart, v.endIndex)
    return out
  }

  static func validHeaderKeyByte(_ c: UInt8) -> Bool { c >= 33 && c <= 126 && c != 0x3a }

  /// Parses a message or part header starting at `start`. Throws `.parse` exactly where
  /// go-message does: a folded first line, a line with no colon, a name outside `ftext`.
  static func readHeader(_ buf: [UInt8], _ start: Int) throws(MIMEFailure) -> ParsedHeader {
    try readHeader(buf[...], start)
  }

  static func readHeader(_ buf: ArraySlice<UInt8>, _ start: Int) throws(MIMEFailure) -> ParsedHeader {
    var fields: [HeaderField] = []
    if start < buf.endIndex && isSpaceByte(buf[start]) { throw .parse }
    var pos = start
    while true {
      let first = readLine(buf, pos)
      if first.eof { return ParsedHeader(fields: fields, bodyStart: buf.endIndex) }
      var kv = Array(buf[first.start..<first.end])
      kv.append(contentsOf: [Bytes.cr, Bytes.lf])
      var p = first.next
      if first.end == first.start { return ParsedHeader(fields: fields, bodyStart: p) }  // the blank line
      while p < buf.endIndex && isSpaceByte(buf[p]) {
        let cont = readLine(buf, p)
        if cont.eof { break }
        kv.append(contentsOf: buf[cont.start..<cont.end])
        kv.append(contentsOf: [Bytes.cr, Bytes.lf])
        p = cont.next
      }
      pos = p

      guard let i = Bytes.index(of: 0x3a, in: kv) else { throw .parse }
      let keyRaw = trimSpaceTab(kv[0..<i])
      for k in keyRaw where !validHeaderKeyByte(k) { throw .parse }
      // An empty key is skipped rather than rejected, as in go-message.
      if !keyRaw.isEmpty {
        fields.append(HeaderField(key: Bytes.latin1Lower(Array(keyRaw)), value: trimAroundNewlines(kv[(i + 1)...])))
      }
    }
  }

  // MARK: - Media type (Go's mime.ParseMediaType through go-message)

  struct MediaType {
    /// Lower-cased media type, or (when it did not parse) the raw field value.
    let type: [UInt8]
    /// Parameter values, already RFC 2047-decoded. Keys are ASCII token text.
    let params: [String: String]
  }

  static let tspecials = Bytes.of("()<>@,;:\\\"/[]?=")
  static func isTSpecial(_ b: UInt8) -> Bool { tspecials.contains(b) }
  static func isTokenChar(_ b: UInt8) -> Bool { b > 0x20 && b < 0x7f && !isTSpecial(b) }

  /// Go's unicode.IsSpace over a binary string: only the bytes whose code point is in the set.
  static func isUnicodeSpaceByte(_ b: UInt8) -> Bool {
    switch b {
    case 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0: true
    default: false
    }
  }

  static func trimLeftUnicodeSpace(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> { s.drop(while: isUnicodeSpaceByte) }

  static func trimUnicodeSpace(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> { Bytes.trim(s, where: isUnicodeSpaceByte) }

  static func consumeToken(_ s: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
    var i = s.startIndex
    while i < s.endIndex, isTokenChar(s[i]) { i += 1 }
    return (s[s.startIndex..<i], s[i...])
  }

  /// Go's consumeValue. Failure is an empty value AND an unconsumed rest, as in Go.
  static func consumeValue(_ v: ArraySlice<UInt8>) -> ([UInt8], ArraySlice<UInt8>) {
    if v.isEmpty { return ([], v) }
    if v.first != 0x22 {
      let (t, r) = consumeToken(v)
      return (Array(t), r)
    }
    var out: [UInt8] = []
    var i = v.startIndex + 1
    while i < v.endIndex {
      let r = v[i]
      if r == 0x22 { return (out, v[(i + 1)...]) }
      // A backslash escapes ONLY a tspecial; otherwise it is a literal backslash.
      if r == 0x5c && i + 1 < v.endIndex && isTSpecial(v[i + 1]) {
        out.append(v[i + 1])
        i += 2
        continue
      }
      if r == Bytes.lf || r == Bytes.cr { return ([], v) }
      out.append(r)
      i += 1
    }
    return ([], v)  // no closing quote
  }

  /// Go's consumeMediaParam: nil when it consumed nothing.
  static func consumeMediaParam(_ v: ArraySlice<UInt8>) -> (key: [UInt8], value: [UInt8], rest: ArraySlice<UInt8>)? {
    var rest = trimLeftUnicodeSpace(v)
    guard rest.first == 0x3b else { return nil }
    rest = trimLeftUnicodeSpace(rest.dropFirst())
    let (param, afterParam) = consumeToken(rest)
    let key = Bytes.latin1Lower(Array(param))
    if key.isEmpty { return nil }
    rest = trimLeftUnicodeSpace(afterParam)
    guard rest.first == 0x3d else { return nil }
    rest = trimLeftUnicodeSpace(rest.dropFirst())
    let (value, rest2) = consumeValue(rest)
    if value.isEmpty && rest2.elementsEqual(rest) { return nil }
    return (key, value, rest2)
  }

  static func fromHexByte(_ b: UInt8) -> Int {
    if b >= 0x30 && b <= 0x39 { return Int(b) - 0x30 }
    if b >= 0x41 && b <= 0x46 { return Int(b) - 0x41 + 10 }
    if b >= 0x61 && b <= 0x66 { return Int(b) - 0x61 + 10 }  // Go accepts lower case too
    return -1
  }

  /// RFC 2231 percent-unescaping; nil on a malformed escape.
  static func percentHexUnescape(_ s: ArraySlice<UInt8>) -> [UInt8]? {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
      if s[i] != 0x25 {
        out.append(s[i])
        i += 1
        continue
      }
      if i + 2 >= s.endIndex { return nil }
      let hi = fromHexByte(s[i + 1])
      let lo = fromHexByte(s[i + 2])
      if hi < 0 || lo < 0 { return nil }
      out.append(UInt8(hi << 4 | lo))
      i += 3
    }
    return out
  }

  /// RFC 2231 `charset'lang'pct`: Go keeps only us-ascii, utf-8 and the empty charset.
  static func decode2231Enc(_ v: [UInt8]) -> [UInt8]? {
    guard let first = Bytes.index(of: 0x27, in: v) else { return nil }
    guard let second = Bytes.index(of: 0x27, in: v, from: first + 1) else { return nil }
    let charset = Bytes.latin1Lower(Array(v[0..<first]))
    guard let encv = percentHexUnescape(v[(second + 1)...]) else { return nil }
    if charset == Bytes.of("us-ascii") || charset == Bytes.of("utf-8") || charset.isEmpty { return encv }
    return nil
  }

  /// Go's checkMediaTypeDisposition.
  static func validMediaType(_ s: [UInt8]) -> Bool {
    let (typ, rest) = consumeToken(s[...])
    if typ.isEmpty { return false }
    if rest.isEmpty { return true }
    guard rest.first == 0x2f else { return false }
    let (subtype, rest2) = consumeToken(rest.dropFirst())
    if subtype.isEmpty { return false }
    return rest2.isEmpty
  }

  /// A Content-Type value, or nil wherever Go returns an error (go-message then uses the raw
  /// value as the type). A trailing semicolon is tolerated, as Go tolerates it.
  static func parseMediaType(_ v: [UInt8]) throws(MIMEFailure) -> MediaType? {
    let semi = Bytes.index(of: 0x3b, in: v)
    let base = v[0..<(semi ?? v.count)]
    let mediatype = Bytes.latin1Lower(Array(trimUnicodeSpace(base)))
    guard validMediaType(mediatype) else { return nil }

    var params: [[UInt8]: [UInt8]] = [:]
    var paramOrder: [[UInt8]] = []
    // RFC 2231 pieces (`name*`, `name*0`, `name*0*`), stitched at the end, by base name.
    var continuation: [[UInt8]: [[UInt8]: [UInt8]]] = [:]
    var continuationOrder: [[UInt8]] = []

    var rest = v[base.count...]
    while !rest.isEmpty {
      rest = trimLeftUnicodeSpace(rest)
      if rest.isEmpty { break }
      guard let p = consumeMediaParam(rest) else {
        if trimUnicodeSpace(rest).elementsEqual([0x3b]) { break }  // a trailing semicolon
        return nil
      }
      if let star = Bytes.index(of: 0x2a, in: p.key) {
        let baseKey = Array(p.key[0..<star])
        if continuation[baseKey] == nil {
          continuation[baseKey] = [:]
          continuationOrder.append(baseKey)
        }
        if let existing = continuation[baseKey]![p.key], existing != p.value { return nil }
        continuation[baseKey]![p.key] = p.value
      } else {
        if let existing = params[p.key] {
          if existing != p.value { return nil }
        } else {
          paramOrder.append(p.key)
        }
        params[p.key] = p.value
      }
      rest = p.rest
    }

    for key in continuationOrder {
      let pieces = continuation[key]!
      if let single = pieces[key + [0x2a]] {
        if let dec = decode2231Enc(single) {
          if params[key] == nil { paramOrder.append(key) }
          params[key] = dec
        }
        continue
      }
      var buf: [UInt8] = []
      var valid = false
      var n = 0
      while true {
        let name = key + [0x2a] + Array(String(n).utf8)
        if let simple = pieces[name] {
          valid = true
          buf.append(contentsOf: simple)
          n += 1
          continue
        }
        guard let encoded = pieces[name + [0x2a]] else { break }
        valid = true
        if n == 0 {
          if let dec = decode2231Enc(encoded) { buf.append(contentsOf: dec) }
        } else if let dec = percentHexUnescape(encoded[...]) {
          buf.append(contentsOf: dec)
        }
        n += 1
      }
      if valid {
        if params[key] == nil { paramOrder.append(key) }
        params[key] = buf
      }
    }

    // go-message RFC 2047-decodes every parameter value after parsing.
    var decoded: [String: String] = [:]
    for k in paramOrder {
      decoded[Bytes.latin1String(k)] = try decodeWords(params[k]!)
    }
    return MediaType(type: mediatype, params: decoded)
  }

  // MARK: - Content-Transfer-Encoding

  static let b64Reverse: [Int16] = {
    var t = [Int16](repeating: -1, count: 256)
    for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
      t[Int(c)] = Int16(i)
    }
    return t
  }()

  /// Strict base64 as go-message decodes a body: space, tab, CR and LF are skipped anywhere,
  /// then everything else is strict (padding required, no data after it, no foreign bytes).
  static func decodeBase64(_ body: some Collection<UInt8>) throws(MIMEFailure) -> [UInt8] {
    var clean: [UInt8] = []
    clean.reserveCapacity(body.count)
    for b in body where !(b == Bytes.sp || b == Bytes.tab || b == Bytes.cr || b == Bytes.lf) { clean.append(b) }
    let n = clean.count
    if n % 4 != 0 { throw .leafDecode }
    var out: [UInt8] = []
    out.reserveCapacity(n / 4 * 3)
    var i = 0
    while i < n {
      let c0 = clean[i], c1 = clean[i + 1], c2 = clean[i + 2], c3 = clean[i + 3]
      let v0 = b64Reverse[Int(c0)], v1 = b64Reverse[Int(c1)]
      if v0 < 0 || v1 < 0 { throw .leafDecode }
      let pad2 = c2 == 0x3d
      let pad3 = c3 == 0x3d
      if pad2 && !pad3 { throw .leafDecode }
      if (pad2 || pad3) && i + 4 != n { throw .leafDecode }
      out.append(UInt8(truncatingIfNeeded: Int(v0) << 2 | Int(v1) >> 4))
      if pad2 { return out }
      let v2 = b64Reverse[Int(c2)]
      if v2 < 0 { throw .leafDecode }
      out.append(UInt8(truncatingIfNeeded: (Int(v1) & 0x0f) << 4 | Int(v2) >> 2))
      if pad3 { return out }
      let v3 = b64Reverse[Int(c3)]
      if v3 < 0 { throw .leafDecode }
      out.append(UInt8(truncatingIfNeeded: (Int(v2) & 0x03) << 6 | Int(v3)))
      i += 4
    }
    return out
  }

  /// Quoted-printable, a line-for-line port of Go's mime/quotedprintable.Reader, with its four
  /// deliberate RFC deviations (soft `=` LF, bare CR/LF pass through, a trailing `=` at EOF after
  /// content is dropped, `=` without two hex digits is literal unless CR/LF follows) and the
  /// whitespace rule (stripped before a hard break, kept before a soft one).
  static func decodeQuotedPrintable(_ body: [UInt8]) throws(MIMEFailure) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(body.count)
    var pos = 0
    while pos < body.count {
      let nl = Bytes.index(of: Bytes.lf, in: body, from: pos)
      let wholeEnd = nl.map { $0 + 1 } ?? body.count
      let whole = body[pos..<wholeEnd]
      let atEOF = nl == nil
      pos = wholeEnd

      let hasLF = !whole.isEmpty && whole.last == Bytes.lf
      let hasCR = whole.count > 1 && whole[whole.endIndex - 2] == Bytes.cr && hasLF

      var end = whole.endIndex
      while end > whole.startIndex {
        let c = whole[end - 1]
        if c == Bytes.lf || c == Bytes.cr || c == Bytes.sp || c == Bytes.tab { end -= 1 } else { break }
      }
      var line = whole[whole.startIndex..<end]
      var softBreak = false

      if line.last == 0x3d {
        var tail = whole[end...]
        while let t = tail.first, t == Bytes.sp || t == Bytes.tab { tail = tail.dropFirst() }
        line = line.dropLast()
        let tailIsBreak =
          (tail.count >= 1 && tail.first == Bytes.lf)
          || (tail.count >= 2 && tail[tail.startIndex] == Bytes.cr && tail[tail.startIndex + 1] == Bytes.lf)
        let trailingEqAtEOF = tail.isEmpty && !line.isEmpty && atEOF
        if !tailIsBreak && !trailingEqAtEOF { throw .leafDecode }
        softBreak = true
      }

      var i = line.startIndex
      while i < line.endIndex {
        let b = line[i]
        if b == 0x3d {
          let hi = i + 1 < line.endIndex ? fromHexByte(line[i + 1]) : -1
          let lo = i + 2 < line.endIndex ? fromHexByte(line[i + 2]) : -1
          if hi >= 0 && lo >= 0 {
            out.append(UInt8(hi << 4 | lo))
            i += 3
            continue
          }
          let next: Int = i + 1 < line.endIndex ? Int(line[i + 1]) : -1
          if line.endIndex - i >= 2 && next != Int(Bytes.cr) && next != Int(Bytes.lf) {
            out.append(0x3d)  // literal =
            i += 1
            continue
          }
          throw .leafDecode
        }
        if b == Bytes.tab || b == Bytes.cr || b == Bytes.lf || b >= 0x80 {
          out.append(b)
          i += 1
          continue
        }
        if b < Bytes.sp || b > 0x7e { throw .leafDecode }
        out.append(b)
        i += 1
      }

      if !softBreak && hasLF {
        if hasCR { out.append(Bytes.cr) }
        out.append(Bytes.lf)
      }
    }
    return out
  }

  enum TransferDecoder {
    case quotedPrintable, base64, identity
  }

  /// The decoder for this Content-Transfer-Encoding, or nil when Go reports it unknown.
  static func transferDecoder(_ cte: [UInt8]) -> TransferDecoder? {
    switch Bytes.latin1Lower(cte) {
    case Bytes.of("quoted-printable"): .quotedPrintable
    case Bytes.of("base64"): .base64
    case Bytes.of("7bit"), Bytes.of("8bit"), Bytes.of("binary"), []: .identity
    default: nil
    }
  }

  static func transferDecode(_ d: TransferDecoder, _ body: [UInt8]) throws(MIMEFailure) -> [UInt8] {
    switch d {
    case .quotedPrintable: try decodeQuotedPrintable(body)
    case .base64: try decodeBase64(body)
    case .identity: body
    }
  }

  // MARK: - RFC 2047 encoded words (Go's mime.WordDecoder)

  /// The trim of `decodeWords` (Go's strings.Trim with the explicit set, on BYTES): the
  /// multi-byte members U+00A0 and U+FEFF are removed only as their exact UTF-8 sequences.
  static let binaryTrimSeqs: [[UInt8]] = [
    [0x09], [0x0a], [0x0b], [0x0c], [0x0d], [0x20], [0xc2, 0xa0], [0xef, 0xbb, 0xbf],
  ]

  static func trimExplicitBinary(_ s: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var start = s.startIndex
    var end = s.endIndex
    outer: while true {
      for q in binaryTrimSeqs where start + q.count <= end && s[start..<(start + q.count)].elementsEqual(q) {
        start += q.count
        continue outer
      }
      break
    }
    outer2: while true {
      for q in binaryTrimSeqs where end - q.count >= start && s[(end - q.count)..<end].elementsEqual(q) {
        end -= q.count
        continue outer2
      }
      break
    }
    return s[start..<end]
  }

  /// One encoded word's content in its declared charset; nil keeps the field's raw value.
  /// mime.WordDecoder handles iso-8859-1 (true Latin-1) and us-ascii (one U+FFFD per high
  /// byte) itself; everything else goes through htmlindex alone.
  static func convertWord(_ charset: [UInt8], _ content: [UInt8]) throws(MIMEFailure) -> String? {
    let cs = Bytes.latin1Lower(charset)
    if cs == Bytes.of("iso-8859-1") { return Bytes.latin1String(content) }
    if cs == Bytes.of("us-ascii") {
      var out = String.UnicodeScalarView()
      for b in content { out.append(b >= 0x80 ? "\u{FFFD}" : Unicode.Scalar(b)) }
      return String(out)
    }
    let label = Bytes.latin1String(cs)
    switch Charset.classifyWord(label) {
    case .singleByte(let t): return Charset.decodeSingleByte(table: t, content)
    case .unsupported: throw .unsupportedCharset(label)
    case .passthrough: return NormText.decodeUTF8(content)
    case .unresolved: return nil
    }
  }

  static func qDecode(_ text: ArraySlice<UInt8>) -> [UInt8]? {
    var out: [UInt8] = []
    var i = text.startIndex
    while i < text.endIndex {
      let c = text[i]
      if c == 0x5f {
        out.append(Bytes.sp)
        i += 1
        continue
      }
      if c == 0x3d {
        if i + 2 >= text.endIndex { return nil }
        let hi = fromHexByte(text[i + 1])
        let lo = fromHexByte(text[i + 2])
        if hi < 0 || lo < 0 { return nil }
        out.append(UInt8(hi << 4 | lo))
        i += 3
        continue
      }
      if (c <= 0x7e && c >= Bytes.sp) || c == Bytes.lf || c == Bytes.cr || c == Bytes.tab {
        out.append(c)
        i += 1
        continue
      }
      return nil
    }
    return out
  }

  /// base64.StdEncoding.DecodeString: strict, padding required, NO whitespace skipping.
  static func bDecode(_ text: ArraySlice<UInt8>) -> [UInt8]? {
    if text.count % 4 != 0 { return nil }
    for c in text where c != 0x3d && b64Reverse[Int(c)] < 0 { return nil }
    return try? decodeBase64(text)
  }

  static func hasNonWhitespace(_ s: ArraySlice<UInt8>) -> Bool {
    s.contains { !($0 == Bytes.sp || $0 == Bytes.tab || $0 == Bytes.lf || $0 == Bytes.cr) }
  }

  /// RFC 2047 decoding of a header value (mime.WordDecoder.DecodeHeader, with the trim Go's
  /// decodeWords applies first). Adjacent encoded words join with NO separator; a word that
  /// fails is left verbatim and scanning resumes after its `=?`. Output is assembled as bytes
  /// and decoded once; where Go would keep invalid UTF-8 from a mislabelled utf-8 word, the
  /// WHATWG decode substitutes U+FFFD (the one documented, accepted divergence, as in TS).
  static func decodeWords(_ raw: [UInt8]) throws(MIMEFailure) -> String {
    let v = Array(trimExplicitBinary(raw[...]))
    if v.isEmpty { return "" }
    guard let firstIdx = Bytes.index(of: [0x3d, 0x3f], in: v) else { return NormText.decodeUTF8(v) }

    var out: [UInt8] = Array(v[0..<firstIdx])
    let n = v.count
    var nextOpen = [Int](repeating: n, count: n + 1)
    var nextQuestion = [Int](repeating: n, count: n + 1)
    var nextClose = [Int](repeating: n, count: n + 1)
    var k = n - 1
    while k >= 0 {
      let isQ = v[k] == 0x3f
      let nextIsEq = k + 1 < n && v[k + 1] == 0x3d
      let nextIsQ = k + 1 < n && v[k + 1] == 0x3f
      nextOpen[k] = v[k] == 0x3d && nextIsQ ? k : nextOpen[k + 1]
      nextQuestion[k] = isQ ? k : nextQuestion[k + 1]
      nextClose[k] = isQ && nextIsEq ? k : nextClose[k + 1]
      k -= 1
    }
    var base = firstIdx
    var betweenWords = false
    while true {
      let start = nextOpen[min(base, n)]
      if start >= n { break }
      var cur = start + 2
      let q = nextQuestion[min(cur, n)]
      if q >= n { break }
      let charset = Array(v[cur..<q])
      cur = q + 1
      if v.count < cur + 4 { break }  // "Q??=".length
      let encoding = v[cur]
      cur += 1
      if v[cur] != 0x3f { break }
      cur += 1
      let j = nextClose[cur]
      if j >= n { break }
      let text = v[cur..<j]
      let end = j + 2

      let content: [UInt8]?
      switch encoding {
      case 0x42, 0x62: content = bDecode(text)
      case 0x51, 0x71: content = qDecode(text)
      default: content = nil
      }
      guard let content else {
        // Go writes the "=?" back out and rescans from just after it.
        betweenWords = false
        out.append(contentsOf: v[base..<(start + 2)])
        base = start + 2
        continue
      }
      if start > base && (!betweenWords || hasNonWhitespace(v[base..<start])) {
        out.append(contentsOf: v[base..<start])
      }
      if Bytes.latin1Lower(charset) == Bytes.of("utf-8") {
        out.append(contentsOf: content)
      } else {
        guard let converted = try convertWord(charset, content) else {
          return NormText.decodeUTF8(v)  // undecodable charset: keep the raw field
        }
        out.append(contentsOf: converted.utf8)
      }
      base = end
      betweenWords = true
    }
    out.append(contentsOf: v[base...])
    return NormText.decodeUTF8(out)
  }

  // MARK: - Addresses

  static func isATextScalar(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x41...0x5a, 0x61...0x7a, 0x30...0x39: true
    default: "!#$%&'*+-/=?^_`{|}~".unicodeScalars.contains(c)
    }
  }

  static func isDotAtom(_ s: ArraySlice<Unicode.Scalar>) -> Bool {
    guard !s.isEmpty, s.first != ".", s.last != "." else { return false }
    var prevDot = false
    for c in s {
      if c == "." {
        if prevDot { return false }  // ".."
        prevDot = true
        continue
      }
      prevDot = false
      if !isATextScalar(c) { return false }
    }
    return true
  }

  static func isQuotedLocal(_ s: ArraySlice<Unicode.Scalar>) -> Bool {
    s.count >= 2 && s.first == "\"" && s.last == "\""
  }

  static func isAddrSpec(_ s: ArraySlice<Unicode.Scalar>) -> Bool {
    guard let at = s.lastIndex(of: "@") else { return false }
    if at == s.startIndex || at == s.endIndex - 1 { return false }
    let local = s[s.startIndex..<at]
    let domain = s[(at + 1)...]
    if !isDotAtom(local) && !isQuotedLocal(local) { return false }
    if domain.first == "[" && domain.last == "]" { return true }
    return isDotAtom(domain)
  }

  /// Splits an address list on top-level commas (quotes, comments and angle-addrs respected).
  static func splitAddressList(_ v: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var out: [[Unicode.Scalar]] = []
    var depthAngle = 0
    var depthParen = 0
    var inQuote = false
    var cur: [Unicode.Scalar] = []
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        cur.append(c)
        if c == "\\" && i + 1 < v.count {
          i += 1
          cur.append(v[i])
        } else if c == "\"" {
          inQuote = false
        }
        i += 1
        continue
      }
      switch c {
      case "\"": inQuote = true; cur.append(c)
      case "<": depthAngle += 1; cur.append(c)
      case ">":
        if depthAngle > 0 { depthAngle -= 1 }
        cur.append(c)
      case "(": depthParen += 1; cur.append(c)
      case ")":
        if depthParen > 0 { depthParen -= 1 }
        cur.append(c)
      case ",":
        if depthAngle == 0 && depthParen == 0 {
          out.append(cur)
          cur = []
        } else {
          cur.append(c)
        }
      default: cur.append(c)
      }
      i += 1
    }
    out.append(cur)
    return out
  }

  /// The addr-spec of a single mailbox, or nil.
  static func parseMailbox(_ s: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar>? {
    let t = s.trimming(.jsTrim)
    if t.isEmpty { return nil }
    if let lt = t.lastIndex(of: "<") {
      guard let gt = t[lt...].firstIndex(of: ">") else { return nil }
      if !t[(gt + 1)...].trimming(.jsTrim).isEmpty { return nil }  // trailing junk: Go rejects it
      let addr = t[(lt + 1)..<gt].trimming(.jsTrim)
      return isAddrSpec(addr) ? addr : nil
    }
    return isAddrSpec(t) ? t : nil
  }

  /// Reduces a From value to its bare address (Go's cascade: an address list, a single
  /// address, a by-hand angle-addr, then the trimmed raw value). `trim` is unwrap's explicit set.
  static func bareAddress(_ v: String) -> String {
    let t = NormText.scalars(NormText.trimExplicit(v))
    if t.isEmpty { return "" }
    let parts = splitAddressList(t)
    if let first = parts.first.flatMap({ parseMailbox($0[...]) }),
      parts.allSatisfy({ parseMailbox($0[...]) != nil })
    {
      return NormText.string(first)
    }
    if let single = parseMailbox(t[...]) { return NormText.string(single) }
    if let i = t.lastIndex(of: "<"), let j = t[i...].firstIndex(of: ">"), j > i {
      return NormText.trimExplicit(NormText.string(t[(i + 1)..<j]))
    }
    return NormText.string(t)
  }

  // MARK: - Entities and the multipart walk

  enum TextMode {
    case utf8
    case singleByte(Int)
    case unsupported(String)
  }

  /// go-message's `New`, including WHICH error it reports. The transfer decoder's EXISTENCE is
  /// decided now (an unknown one is an error); whether it SUCCEEDS is decided when the text is
  /// read, which is the difference between an aborted walk and a skipped leaf.
  struct Entity {
    let mediaType: [UInt8]
    let params: [String: String]
    let rawBody: ArraySlice<UInt8>
    let decoder: TransferDecoder?
    let isMultipart: Bool
    let mode: TextMode
    /// What NextPart would report: advisory at the top level, fatal inside a multipart.
    let failed: Bool

    func decodedBody() throws(MIMEFailure) -> [UInt8] {
      guard !isMultipart, let decoder else { return Array(rawBody) }
      return try MIME.transferDecode(decoder, Array(rawBody))
    }

    func text() throws(MIMEFailure) -> String {
      switch mode {
      case .utf8: return NormText.decodeUTF8(try decodedBody())
      case .singleByte(let t): return Charset.decodeSingleByte(table: t, try decodedBody())
      case .unsupported(let label): throw .unsupportedCharset(label)
      }
    }
  }

  static func hasPrefix(_ s: [UInt8], _ p: StaticString) -> Bool { Bytes.hasPrefix(s, Bytes.of(p)) }

  static func newEntity(_ header: ParsedHeader, _ rawBody: ArraySlice<UInt8>) throws(MIMEFailure) -> Entity {
    let ct = header.get("content-type")
    var type: [UInt8] = Bytes.of("text/plain")
    var params: [String: String] = [:]
    if !ct.isEmpty {
      if let mt = try parseMediaType(ct) {
        type = mt.type
        params = mt.params
      } else {
        type = ct
      }
    }
    let cte = header.get("content-transfer-encoding")
    let isMultipart = hasPrefix(type, "multipart/")
    let decoder = transferDecoder(cte)
    var failed = !isMultipart && decoder == nil
    var mode = TextMode.utf8
    if hasPrefix(type, "text/"), let label = params["charset"] {
      switch Charset.classify(label) {
      case .singleByte(let t): mode = .singleByte(t)
      case .unsupported: mode = .unsupported(label)
      case .unresolved: failed = true  // go-message reports the error AND leaves the body undecoded
      case .passthrough: break
      }
    }
    return Entity(
      mediaType: type, params: params, rawBody: rawBody, decoder: decoder, isMultipart: isMultipart,
      mode: mode, failed: failed)
  }

  /// go-message/textproto.MultipartReader over the whole buffer. `next()` throws `.walkAbort`
  /// (or `.parse` for a bad part header) exactly where Go's NextPart returns an error.
  struct Multipart {
    let body: ArraySlice<UInt8>
    let dashBoundary: [UInt8]
    let dashBoundaryDash: [UInt8]
    var nl: [UInt8] = [Bytes.cr, Bytes.lf]
    var nlDashBoundary: [UInt8]
    var pos: Int
    var partsRead = 0
    var expectNewPart = false
    var done = false

    init(body: ArraySlice<UInt8>, boundary: String) throws(MIMEFailure) {
      if boundary.isEmpty { throw .walkAbort }
      self.body = body
      pos = body.startIndex
      let b = Array(boundary.utf8)
      dashBoundary = [0x2d, 0x2d] + b
      dashBoundaryDash = dashBoundary + [0x2d, 0x2d]
      nlDashBoundary = [Bytes.cr, Bytes.lf] + dashBoundary
    }

    func isFinalBoundary(_ line: ArraySlice<UInt8>) -> Bool {
      guard line.starts(with: dashBoundaryDash) else { return false }
      let rest = line.dropFirst(dashBoundaryDash.count).drop(while: MIME.isSpaceByte)
      return rest.isEmpty || rest.elementsEqual(nl)
    }

    mutating func isBoundaryDelimiter(_ line: ArraySlice<UInt8>) -> Bool {
      guard line.starts(with: dashBoundary) else { return false }
      let rest = line.dropFirst(dashBoundary.count).drop(while: MIME.isSpaceByte)
      // First part only: switch to bare-LF mode when the mail uses LF endings.
      if partsRead == 0 && rest.count == 1 && rest.first == Bytes.lf {
        nl = [Bytes.lf]
        nlDashBoundary = [Bytes.lf] + dashBoundary
      }
      return rest.elementsEqual(nl)
    }

    func boundaryMatchesAt(_ at: Int, _ prefix: [UInt8]) -> Bool {
      guard Bytes.hasPrefix(body, prefix, at: at) else { return false }
      let after = at + prefix.count
      if after == body.endIndex { return true }
      let c = body[after]
      return c == Bytes.sp || c == Bytes.tab || c == Bytes.cr || c == Bytes.lf || c == 0x2d
    }

    mutating func next() throws(MIMEFailure) -> (header: ParsedHeader, rawBody: ArraySlice<UInt8>)? {
      if done { return nil }
      while true {
        let idx = Bytes.index(of: Bytes.lf, in: body, from: pos)
        let line = body[pos..<(idx.map { $0 + 1 } ?? body.endIndex)]
        let sawLF = idx != nil
        if !sawLF && isFinalBoundary(line) {
          done = true
          return nil
        }
        if !sawLF { throw .walkAbort }  // EOF, or an unexpected one
        pos = idx! + 1

        if isBoundaryDelimiter(line) {
          partsRead += 1
          let header = try MIME.readHeader(body, pos)
          let bodyStart = header.bodyStart
          var end: Int? = nil
          if bodyStart <= body.endIndex && boundaryMatchesAt(bodyStart, dashBoundary) {
            end = bodyStart  // a body that starts with the boundary is empty
          } else {
            var i = bodyStart
            while let at = Bytes.index(of: nlDashBoundary, in: body, from: i) {
              if boundaryMatchesAt(at, nlDashBoundary) {
                end = at
                break
              }
              i = at + 1
            }
          }
          // Go: io.ErrUnexpectedEOF. The leaf is undecodable AND the walk aborts.
          guard let end else { throw .walkAbort }
          pos = end
          expectNewPart = false
          return (header, body[bodyStart..<end])
        }

        if isFinalBoundary(line) {
          done = true
          return nil
        }
        if expectNewPart { throw .walkAbort }
        if partsRead == 0 { continue }  // preamble
        if line.elementsEqual(nl) {
          expectNewPart = true
          continue
        }
        throw .walkAbort
      }
    }
  }

  /// Everything after the first blank line (CRLF CRLF or LF LF, whichever comes first), or the
  /// whole message when it has none.
  static func rawBodyAfterHeaders(_ raw: [UInt8]) -> ArraySlice<UInt8> {
    let crlf = Bytes.index(of: [0x0d, 0x0a, 0x0d, 0x0a], in: raw)
    let lf = Bytes.index(of: [0x0a, 0x0a], in: raw)
    if let crlf, lf == nil || crlf < lf! { return raw[(crlf + 4)...] }
    if let lf { return raw[(lf + 2)...] }
    return raw[...]
  }
}
