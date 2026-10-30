public struct WordTagger: Sendable, Equatable {
  public static let memoryOnly = WordTagger(id: "memory") { word in
    var h: UInt32 = 2_166_136_261
    for b in word.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return UInt16(truncatingIfNeeded: (h >> 16) ^ h)
  }

  let id: String
  public let tag: @Sendable (String) -> UInt16

  public init(id: String, tag: @escaping @Sendable (String) -> UInt16) {
    self.id = id
    self.tag = tag
  }

  public var isDeviceKeyed: Bool { id != Self.memoryOnly.id }

  public static func == (a: WordTagger, b: WordTagger) -> Bool { a.id == b.id }
}

public struct LearnedLayouts: Codable, Sendable, Equatable {
  public static let senderLimit = 32
  public static let layoutLimitPerSender = 40
  public static let exampleLimitPerLayout = 16
  public static let tokenLimitPerMail = 400
  public static let tokenBudgetPerSender = 24_000

  public internal(set) var senders: [String: SenderLayouts]
  var clock: Int64
  public var wordTagger = WordTagger.memoryOnly

  enum CodingKeys: String, CodingKey {
    case senders
    case clock
  }

  public init() {
    senders = [:]
    clock = 0
  }

  public var isEmpty: Bool { senders.isEmpty }

  public static func senderKey(_ sender: String) -> String { sender.lowercased() }

  func layouts(for sender: String) -> SenderLayouts {
    senders[Self.senderKey(sender)] ?? SenderLayouts()
  }

  var leastRecentSender: String? {
    senders.min(by: { ($0.value.lastRead, $0.key) < ($1.value.lastRead, $1.key) })?.key
  }

  @discardableResult
  public mutating func dropLeastRecentSender() -> Bool {
    guard let oldest = leastRecentSender else { return false }
    senders.removeValue(forKey: oldest)
    return true
  }

  mutating func store(_ s: SenderLayouts, for sender: String) {
    clock += 1
    var s = s
    s.lastRead = clock
    senders[Self.senderKey(sender)] = s
    while senders.count > Self.senderLimit, let oldest = leastRecentSender {
      senders.removeValue(forKey: oldest)
    }
  }
}

public struct SenderLayouts: Codable, Sendable, Equatable {
  public internal(set) var layouts: [LearnedLayout]
  var clock: Int
  var lastRead: Int64

  init() {
    layouts = []
    clock = 0
    lastRead = 0
  }

  var leastRecentlyUsedLayout: Int? {
    layouts.indices.min(by: { layouts[$0].lastUsed < layouts[$1].lastUsed })
  }
}

public struct LearnedLayout: Codable, Sendable, Equatable {
  public internal(set) var anchors: [LayoutSlot]
  public internal(set) var examples: [SlotFillers]
  public internal(set) var seen: Int
  var lastUsed: Int

  enum CodingKeys: String, CodingKey {
    case anchors = "a"
    case examples = "x"
    case seen = "n"
    case lastUsed = "u"
  }
}

public struct LayoutSlot: Codable, Sendable, Equatable {
  var kind: IElemKind
  var key: String
  var cls: IClass

  enum CodingKeys: String, CodingKey {
    case kind = "k"
    case key = "v"
    case cls = "c"
  }
}

extension LayoutSlot {
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(IElemKind.self, forKey: .kind)
    let key = try c.decode(String.self, forKey: .key)
    let cls = try c.decode(IClass.self, forKey: .cls)
    if kind == .const && cls == .word && !LayoutCodec.isStoredWord(key) {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "slot"))
    }
    self.init(kind: kind, key: key, cls: cls)
  }
}

public struct SlotFillers: Codable, Sendable, Equatable {
  var tokens: [FillerToken]

  enum CodingKeys: String, CodingKey {
    case tokens = "t"
  }
}

enum FillerToken: Codable, Sendable, Equatable {
  case anchor(Int, spaceBefore: Bool)
  case free(String, cls: IClass, spaceBefore: Bool)

  init(from decoder: any Decoder) throws {
    if let packed = try? decoder.singleValueContainer().decode(Int.self) {
      guard packed >= 0 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "anchor")) }
      self = .anchor(packed >> 1, spaceBefore: packed & 1 == 1)
      return
    }
    var c = try decoder.unkeyedContainer()
    let raw = try c.decode(String.self)
    let cls = try c.decode(IClass.self)
    guard LayoutCodec.isStoredShape(raw, cls) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "free"))
    }
    self = .free(raw, cls: cls, spaceBefore: try c.decode(Bool.self))
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .anchor(let e, let space):
      var c = encoder.singleValueContainer()
      try c.encode(e << 1 | (space ? 1 : 0))
    case .free(let raw, let cls, let space):
      var c = encoder.unkeyedContainer()
      try c.encode(raw)
      try c.encode(cls)
      try c.encode(space)
    }
  }
}

struct RuntimeLayout {
  var template: [IElem]
  var examples: [[IToken]]
  var seen: Int
  var lastUsed: Int
}

enum LayoutCodec {
  static func elems(_ slots: [LayoutSlot], _ interner: inout IInterner) -> [IElem] {
    slots.map { s in
      switch s.kind {
      case .gap: IElem.gap
      case .typed: IElem(kind: .typed, code: ILex.typedCode(s.cls), key: "", cls: s.cls)
      case .const: IElem(kind: .const, code: interner.code(s.key), key: s.key, cls: s.cls)
      }
    }
  }

  static func slots(_ t: [IElem], _ tagger: WordTagger) -> [LayoutSlot] {
    t.map { LayoutSlot(kind: $0.kind, key: $0.kind == .const ? shapeKey($0.key, $0.cls, tagger) : $0.key, cls: $0.cls) }
  }

  static let valueShape = "0"

  static func shapeKey(_ key: String, _ cls: IClass, _ tagger: WordTagger) -> String {
    switch cls {
    case .money, .num, .cur: return valueShape
    case .nl, .punct: return key
    case .word: return isStoredWord(key) ? key : wordTag(key, tagger)
    }
  }

  static func wordTag(_ key: String, _ tagger: WordTagger) -> String {
    let hex = String(tagger.tag(key), radix: 16)
    return "#" + String(repeating: "0", count: 4 - hex.utf8.count) + hex
  }

  static func isWordTag(_ key: String) -> Bool {
    let c = Array(key.utf8)
    return c.count == 5 && c[0] == 35 && c[1...].allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
  }

  static func isStoredWord(_ key: String) -> Bool {
    key == ILex.subjKey || ILex.layoutWords.contains(key) || isWordTag(key)
  }

  static func isStoredShape(_ raw: String, _ cls: IClass) -> Bool {
    switch cls {
    case .money, .num, .cur: return raw == valueShape
    case .nl: return raw == ILex.nlKey
    case .punct: return raw.allSatisfy { ITokenizer.trailPunct.contains($0) || ITokenizer.leadPunct.contains($0) }
    case .word: return isStoredWord(raw)
    }
  }

  static func shape(_ toks: ArraySlice<IToken>, _ tagger: WordTagger) -> String {
    toks.filter { $0.cls != .nl && $0.key != ILex.subjKey }.map { shapeKey($0.key, $0.cls, tagger) }.joined(separator: " ")
  }

  static func anchorKeys(_ slots: [LayoutSlot]) -> Set<String> {
    Set(slots.filter { $0.kind == .const }.map(\.key))
  }

  static func defaultRaw(_ key: String, _ cls: IClass) -> String { cls == .nl ? "\n" : key }

  static func decode(_ f: SlotFillers, template: [IElem], _ interner: inout IInterner) -> [IToken]? {
    var out: [IToken] = []
    out.reserveCapacity(f.tokens.count)
    var line = 0
    for t in f.tokens {
      var tok: IToken
      switch t {
      case .anchor(let e, let space):
        guard template.indices.contains(e) else { return nil }
        let el = template[e]
        tok = IToken(raw: defaultRaw(el.key, el.cls), key: el.key, cls: el.cls, line: line, spaceBefore: space, code: el.code)
      case .free(let raw, let cls, let space):
        let key = cls == .nl ? ILex.nlKey : raw.lowercased()
        tok = IToken(raw: raw, key: key, cls: cls, line: line, spaceBefore: space, code: ILex.code(cls, key, &interner))
      }
      out.append(tok)
      if tok.cls == .nl { line += 1 }
    }
    return out
  }

  static func encode(_ toks: [IToken], template: [IElem], applied: IApplied, _ tagger: WordTagger) -> SlotFillers {
    var anchorOf: [Int: Int] = [:]
    for (e, j) in applied.elemTok.enumerated() {
      if let j = j, template[e].kind == .const { anchorOf[j] = e }
    }
    return SlotFillers(
      tokens: toks.enumerated().map { j, t in
        if let e = anchorOf[j] { return .anchor(e, spaceBefore: t.spaceBefore) }
        return .free(shapeKey(t.key, t.cls, tagger), cls: t.cls, spaceBefore: t.spaceBefore)
      })
  }
}
