import CoreExtract
import CorePrimitives
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

public struct MailReaderState: Sendable, Equatable, Codable {
  public static let version = 2
  public static let marker = "extract@1"
  public static let bankLimit = 64
  public static let byteLimit = 4_000_000

  public var version = MailReaderState.version
  public var address: String?
  public var layouts = LearnedLayouts()
  public var counts: [String: ReaderCounts] = [:]

  public init(address: String? = nil) { self.address = address }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
    address = try? c.decodeIfPresent(String.self, forKey: .address)
    layouts = version == Self.version ? ((try? c.decodeIfPresent(LearnedLayouts.self, forKey: .layouts)) ?? LearnedLayouts()) : LearnedLayouts()
    counts = (try? c.decodeIfPresent([String: ReaderCounts].self, forKey: .counts)) ?? [:]
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
