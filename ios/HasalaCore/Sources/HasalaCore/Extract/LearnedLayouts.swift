public struct LearnedLayouts: Codable, Sendable, Equatable {
  public static let senderLimit = 32
  public static let layoutLimitPerSender = 40
  public static let exampleLimitPerLayout = 16
  public static let tokenLimitPerMail = 400
  public static let tokenBudgetPerSender = 24_000

  public internal(set) var senders: [String: SenderLayouts]
  var clock: Int64

  public init() {
    senders = [:]
    clock = 0
  }

  public var isEmpty: Bool { senders.isEmpty }

  public static func senderKey(_ sender: String) -> String { sender.lowercased() }

  func layouts(for sender: String) -> SenderLayouts {
    senders[Self.senderKey(sender)] ?? SenderLayouts()
  }

  @discardableResult
  public mutating func dropLeastRecentSender() -> Bool {
    guard let oldest = senders.min(by: { ($0.value.lastRead, $0.key) < ($1.value.lastRead, $1.key) })?.key else {
      return false
    }
    senders.removeValue(forKey: oldest)
    return true
  }

  mutating func store(_ s: SenderLayouts, for sender: String) {
    clock += 1
    var s = s
    s.lastRead = clock
    senders[Self.senderKey(sender)] = s
    while senders.count > Self.senderLimit,
      let oldest = senders.min(by: { ($0.value.lastRead, $0.key) < ($1.value.lastRead, $1.key) })?.key
    {
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

public struct SlotFillers: Codable, Sendable, Equatable {
  var tokens: [FillerToken]

  enum CodingKeys: String, CodingKey {
    case tokens = "t"
  }
}

enum FillerToken: Codable, Sendable, Equatable {
  case anchor(Int, spaceBefore: Bool, raw: String?)
  case free(String, cls: IClass, spaceBefore: Bool)

  init(from decoder: any Decoder) throws {
    if let packed = try? decoder.singleValueContainer().decode(Int.self) {
      guard packed >= 0 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "anchor")) }
      self = .anchor(packed >> 1, spaceBefore: packed & 1 == 1, raw: nil)
      return
    }
    var c = try decoder.unkeyedContainer()
    if let raw = try? c.decode(String.self) {
      let cls = try c.decode(IClass.self)
      self = .free(raw, cls: cls, spaceBefore: try c.decode(Bool.self))
    } else {
      let e = try c.decode(Int.self)
      guard e >= 0 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "anchor")) }
      let space = try c.decode(Bool.self)
      self = .anchor(e, spaceBefore: space, raw: try c.decode(String.self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .anchor(let e, let space, nil):
      var c = encoder.singleValueContainer()
      try c.encode(e << 1 | (space ? 1 : 0))
    case .anchor(let e, let space, let raw?):
      var c = encoder.unkeyedContainer()
      try c.encode(e)
      try c.encode(space)
      try c.encode(raw)
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
  static func typedCode(_ cls: IClass) -> Int32 {
    switch cls {
    case .money: ILex.moneyCode
    case .num: ILex.numCode
    default: ILex.curCode
    }
  }

  static func elems(_ slots: [LayoutSlot], _ interner: inout IInterner) -> [IElem] {
    slots.map { s in
      switch s.kind {
      case .gap: IElem.gap
      case .typed: IElem(kind: .typed, code: typedCode(s.cls), key: "", cls: s.cls)
      case .const: IElem(kind: .const, code: interner.code(s.key), key: s.key, cls: s.cls)
      }
    }
  }

  static func slots(_ t: [IElem]) -> [LayoutSlot] {
    t.map { LayoutSlot(kind: $0.kind, key: $0.key, cls: $0.cls) }
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
      case .anchor(let e, let space, let raw):
        guard template.indices.contains(e) else { return nil }
        let el = template[e]
        tok = IToken(raw: raw ?? defaultRaw(el.key, el.cls), key: el.key, cls: el.cls, line: line, spaceBefore: space, code: el.code)
      case .free(let raw, let cls, let space):
        let key = cls == .nl ? ILex.nlKey : raw.lowercased()
        let code: Int32
        switch cls {
        case .money, .num, .cur: code = typedCode(cls)
        default: code = interner.code(key)
        }
        tok = IToken(raw: raw, key: key, cls: cls, line: line, spaceBefore: space, code: code)
      }
      out.append(tok)
      if tok.cls == .nl { line += 1 }
    }
    return out
  }

  static func encode(_ toks: [IToken], template: [IElem], applied: IApplied) -> SlotFillers {
    var anchorOf: [Int: Int] = [:]
    for (e, j) in applied.elemTok.enumerated() {
      if let j = j, template[e].kind == .const { anchorOf[j] = e }
    }
    return SlotFillers(
      tokens: toks.enumerated().map { j, t in
        if let e = anchorOf[j] {
          let raw = t.raw == defaultRaw(t.key, t.cls) ? nil : t.raw
          return .anchor(e, spaceBefore: t.spaceBefore, raw: raw)
        }
        return .free(t.raw, cls: t.cls, spaceBefore: t.spaceBefore)
      })
  }
}
