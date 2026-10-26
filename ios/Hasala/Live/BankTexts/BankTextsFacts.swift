import CoreStore
import CoreTime
import Foundation
import Synchronization

nonisolated struct BankTextsFactsData: Codable, Equatable, Sendable {
  struct SetAside: Codable, Equatable, Sendable {
    var sender: String
    var bank: String?
    var day: Int64
    var kind: BankTextDropKind
    var count: Int
  }

  struct DayCount: Codable, Equatable, Sendable {
    var day: Int64
    var count: Int
  }

  struct LinkCopy: Codable, Equatable, Sendable {
    var linked: Bool
    var learnedAtMs: Int64
  }

  var chosen = false
  var lastRunMs: Int64?
  var lastKeptMs: [String: Int64] = [:]
  var setAside: [SetAside] = []
  var ignored: [DayCount] = []
  var testPassedMs: Int64?
  var testOpenedMs: Int64?
  var link: LinkCopy?

  static let keptDays: Int64 = 30
  static let testWindowMs: Int64 = 10 * 60 * 1000

  static func day(_ ms: Int64) -> Int64 {
    Civil.floorDiv(ms + LocalClock.offsetMinutes * 60_000, 86_400_000)
  }

  func testWindowOpen(nowMs: Int64) -> Bool {
    guard let opened = testOpenedMs else { return false }
    return nowMs >= opened && nowMs < opened + Self.testWindowMs
  }

  mutating func prune(nowMs: Int64) {
    let today = Self.day(nowMs)
    let fresh: (Int64) -> Bool = { today - $0 < Self.keptDays }
    setAside.removeAll { !fresh($0.day) || $0.count <= 0 }
    ignored.removeAll { !fresh($0.day) || $0.count <= 0 }
    if let opened = testOpenedMs, nowMs >= opened + Self.testWindowMs || nowMs < opened { testOpenedMs = nil }
  }

  mutating func addSetAside(sender: String, bank: String?, kind: BankTextDropKind, atMs: Int64) {
    let day = Self.day(atMs)
    if let i = setAside.firstIndex(where: { $0.sender == sender && $0.day == day && $0.kind == kind }) {
      setAside[i].count += 1
      if setAside[i].bank == nil { setAside[i].bank = bank }
    } else {
      setAside.append(SetAside(sender: sender, bank: bank, day: day, kind: kind, count: 1))
    }
  }

  mutating func addIgnored(_ n: Int = 1, atMs: Int64) {
    guard n > 0 else { return }
    let day = Self.day(atMs)
    if let i = ignored.firstIndex(where: { $0.day == day }) {
      ignored[i].count += n
    } else {
      ignored.append(DayCount(day: day, count: n))
    }
  }

  func ignoredTotal(nowMs: Int64) -> Int {
    let today = Self.day(nowMs)
    return ignored.filter { today - $0.day < Self.keptDays }.reduce(0) { $0 + $1.count }
  }

  func setAsideRecent(nowMs: Int64) -> [SetAside] {
    let today = Self.day(nowMs)
    return setAside.filter { today - $0.day < Self.keptDays && $0.count > 0 }
  }

  func sawAutomationRun(nowMs: Int64) -> Bool {
    lastRunMs != nil || ignoredTotal(nowMs: nowMs) > 0
  }
}

nonisolated enum BankTextsFactsError: Error, Equatable, Sendable {
  case unavailable
}

nonisolated final class BankTextsFacts: Sendable {
  static let changed = Notification.Name("app.hasala.bankTexts.facts.changed")
  static let shared = BankTextsFacts(directory: defaultDirectory())

  private let file: URL?
  private let cache = Mutex<BankTextsFactsData?>(nil)
  private let lock = NSLock()

  init(directory: URL?) {
    file = directory?.appendingPathComponent("facts.json")
  }

  static func defaultDirectory() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Hasala", isDirectory: true)
      .appendingPathComponent("texts", isDirectory: true)
  }

  func read(nowMs: Int64) -> BankTextsFactsData {
    lock.withLock {
      var data = (try? loaded()) ?? BankTextsFactsData()
      data.prune(nowMs: nowMs)
      return data
    }
  }

  @discardableResult
  func update(nowMs: Int64, _ change: (inout BankTextsFactsData) -> Void) throws(BankTextsFactsError)
    -> BankTextsFactsData
  {
    lock.lock()
    var data: BankTextsFactsData
    do {
      data = try loaded()
      data.prune(nowMs: nowMs)
      change(&data)
      data.prune(nowMs: nowMs)
      try save(data)
    } catch {
      lock.unlock()
      throw error
    }
    let next = data
    cache.withLock { $0 = next }
    lock.unlock()
    Self.announce()
    return next
  }

  func forget() {
    lock.withLock {
      cache.withLock { $0 = BankTextsFactsData() }
      if let file { try? FileManager.default.removeItem(at: file) }
    }
    Self.announce()
  }

  var fileExists: Bool {
    guard let file else { return false }
    return FileManager.default.fileExists(atPath: file.path)
  }

  private func loaded() throws(BankTextsFactsError) -> BankTextsFactsData {
    if let cached = cache.withLock({ $0 }) { return cached }
    var data = BankTextsFactsData()
    if let file, FileManager.default.fileExists(atPath: file.path) {
      guard let bytes = try? Data(contentsOf: file) else { throw .unavailable }
      if let decoded = try? JSONDecoder().decode(BankTextsFactsData.self, from: bytes) { data = decoded }
    }
    cache.withLock { $0 = data }
    return data
  }

  private func save(_ data: BankTextsFactsData) throws(BankTextsFactsError) {
    guard let file else { return }
    do {
      try FileHygiene.prepareDirectory(file.deletingLastPathComponent())
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      #if os(iOS)
        try encoder.encode(data).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      #else
        try encoder.encode(data).write(to: file, options: [.atomic])
      #endif
    } catch {
      throw .unavailable
    }
  }

  private static func announce() {
    Task { @MainActor in NotificationCenter.default.post(name: changed, object: nil) }
  }
}

nonisolated struct LockedTextsMarker: Codable, Equatable, Sendable {
  var count: Int
  var latestMinuteMs: Int64
}

nonisolated final class LockedTextsMarkerFile: Sendable {
  static let shared = LockedTextsMarkerFile(directory: defaultDirectory())

  private let file: URL?
  private let lock = NSLock()

  init(directory: URL?) {
    file = directory?.appendingPathComponent("marker.json")
  }

  static func defaultDirectory() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Hasala", isDirectory: true)
      .appendingPathComponent("texts-locked", isDirectory: true)
  }

  static func minute(_ ms: Int64) -> Int64 { Civil.floorDiv(ms, 60_000) * 60_000 }

  func read() -> LockedTextsMarker? {
    lock.withLock { load() }
  }

  @discardableResult
  func add(arrivedAtMs: Int64) -> Bool {
    lock.withLock {
      guard let file else { return false }
      var marker = load() ?? LockedTextsMarker(count: 0, latestMinuteMs: 0)
      marker.count += 1
      marker.latestMinuteMs = max(marker.latestMinuteMs, Self.minute(arrivedAtMs))
      do {
        let dir = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
          #if os(iOS)
            try FileManager.default.createDirectory(
              at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.none])
          #else
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          #endif
          try? FileHygiene.exclude(dir)
        }
        #if os(iOS)
          try JSONEncoder().encode(marker).write(to: file, options: [.atomic, .noFileProtection])
        #else
          try JSONEncoder().encode(marker).write(to: file, options: [.atomic])
        #endif
        return true
      } catch {
        return false
      }
    }
  }

  func remove() {
    lock.withLock {
      if let file { try? FileManager.default.removeItem(at: file) }
    }
  }

  private func load() -> LockedTextsMarker? {
    guard let file, let bytes = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(LockedTextsMarker.self, from: bytes)
  }
}
