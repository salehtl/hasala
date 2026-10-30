import CoreExtract
import CorePrimitives
import CoreStore
import Foundation

public struct ReaderCounts: Sendable, Equatable, Codable {
  public var templateHit = 0
  public var readerAgreed = 0
  public var readerDisagreed = 0
  public var readerOnly = 0
  public var pendingSetAside = 0

  public init() {}

  enum CodingKeys: String, CodingKey {
    case templateHit = "template_hit"
    case readerAgreed = "reader_agreed"
    case readerDisagreed = "reader_disagreed"
    case readerOnly = "reader_only"
    case pendingSetAside = "pending_set_aside"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    templateHit = (try? c.decodeIfPresent(Int.self, forKey: .templateHit)) ?? 0
    readerAgreed = (try? c.decodeIfPresent(Int.self, forKey: .readerAgreed)) ?? 0
    readerDisagreed = (try? c.decodeIfPresent(Int.self, forKey: .readerDisagreed)) ?? 0
    readerOnly = (try? c.decodeIfPresent(Int.self, forKey: .readerOnly)) ?? 0
    pendingSetAside = (try? c.decodeIfPresent(Int.self, forKey: .pendingSetAside)) ?? 0
  }
}

public struct MailReaderKey: Sendable, Equatable {
  public static let secretBytes = 32
  static let wordDomain = Data("hasala.reader.word.v1\u{0}".utf8)
  static let checkDomain = Data("hasala.reader.check.v1".utf8)

  public let tagger: WordTagger
  public let check: String

  public init?(secret: Data) {
    guard secret.count == Self.secretBytes else { return nil }
    check = Hex.encode(hmacSHA256(key: secret, message: Self.checkDomain).prefix(16))
    tagger = WordTagger(id: check) { word in
      let mac = hmacSHA256(key: secret, message: Self.wordDomain + Data(word.utf8))
      return UInt16(mac[mac.startIndex]) << 8 | UInt16(mac[mac.startIndex + 1])
    }
  }
}

public protocol MailReaderKeyStore: Sendable {
  func read() throws(SecretUnavailable) -> Data?
  func write(_ secret: Data) throws(SecretUnavailable)
  func delete() throws(SecretUnavailable)
}

public struct SecretsMailReaderKeyStore: MailReaderKeyStore {
  let store: any SecretStore

  public init(secrets: Secrets) { store = secrets.store }

  public func read() throws(SecretUnavailable) -> Data? {
    do { return try store.read(.readerWordKey) } catch { throw SecretUnavailable() }
  }

  public func write(_ secret: Data) throws(SecretUnavailable) {
    do { try store.write(.readerWordKey, secret) } catch { throw SecretUnavailable() }
  }

  public func delete() throws(SecretUnavailable) {
    do { try store.delete(.readerWordKey) } catch { throw SecretUnavailable() }
  }
}

public final class MemoryMailReaderKeyStore: MailReaderKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secret: Data?
  private var unavailable = false

  public init(secret: Data? = nil) { self.secret = secret }

  public var held: Data? {
    lock.lock()
    defer { lock.unlock() }
    return secret
  }

  public var locked: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return unavailable
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      unavailable = newValue
    }
  }

  public func read() throws(SecretUnavailable) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if unavailable { throw SecretUnavailable() }
    return secret
  }

  public func write(_ s: Data) throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if unavailable { throw SecretUnavailable() }
    secret = s
  }

  public func delete() throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if unavailable { throw SecretUnavailable() }
    secret = nil
  }
}

public struct MailReaderState: Sendable, Equatable, Codable {
  public static let version = 3
  public static let marker = "extract@1"
  public static let bankLimit = 64
  public static let byteLimit = 4_000_000

  public var version = MailReaderState.version
  public var address: String?
  public var layouts = LearnedLayouts()
  public var counts: [String: ReaderCounts] = [:]
  public internal(set) var keyCheck: String?
  public var training = true

  enum CodingKeys: String, CodingKey {
    case version
    case address
    case layouts
    case counts
    case keyCheck = "key_check"
  }

  public init(address: String? = nil) { self.address = address }

  public mutating func attach(_ key: MailReaderKey) {
    if keyCheck != key.check { layouts = LearnedLayouts() }
    keyCheck = key.check
    layouts.wordTagger = key.tagger
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
    address = try? c.decodeIfPresent(String.self, forKey: .address)
    layouts = version == Self.version ? ((try? c.decodeIfPresent(LearnedLayouts.self, forKey: .layouts)) ?? LearnedLayouts()) : LearnedLayouts()
    counts = (try? c.decodeIfPresent([String: ReaderCounts].self, forKey: .counts)) ?? [:]
    keyCheck = try? c.decodeIfPresent(String.self, forKey: .keyCheck)
    version = Self.version
  }

  public func belongs(to address: String?) -> Bool {
    (self.address ?? "").lowercased() == (address ?? "").lowercased()
  }

  mutating func bump(_ bank: String, _ change: (inout ReaderCounts) -> Void) {
    let key = bank.isEmpty ? "unknown" : bank
    if counts[key] == nil && counts.count >= Self.bankLimit { return }
    change(&counts[key, default: ReaderCounts()])
  }

  static let log = CoreLog(category: "CoreMailbox")

  public func encoded(limit: Int = byteLimit) -> Data? {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    var trimmed = self
    if !layouts.wordTagger.isDeviceKeyed {
      trimmed.layouts = LearnedLayouts()
      trimmed.keyCheck = nil
    }
    var dropped = 0
    while true {
      guard let data = try? enc.encode(trimmed) else { return nil }
      if data.count <= limit || !trimmed.layouts.dropLeastRecentSender() {
        if dropped > 0 {
          Self.log.notice("mailbox.reader_layouts_trimmed", .count("senders", dropped), .count("bytes", data.count))
        }
        return data
      }
      dropped += 1
    }
  }

  public static func decoded(_ data: Data?) -> MailReaderState? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(MailReaderState.self, from: data)
  }
}
