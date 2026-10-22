import Foundation
import SwiftUI

nonisolated enum RunOffer {
  static let returningGroups = 20
  static let opensBeforeFallback = 2

  enum Mailbox: Equatable, Sendable {
    case active
    case elsewhere
    case importing
    case awaitingCards
    case none
  }

  struct Load: Equatable, Sendable {
    var mailbox: Mailbox
    var caughtUp: Bool

    init(mailbox: Mailbox = .none, caughtUp: Bool = false) {
      self.mailbox = mailbox
      self.caughtUp = caughtUp
    }
  }

  struct Facts: Equatable, Sendable {
    var enabled: Bool
    var load: Load
    var waitingNames: Int
    var runActive: Bool
    var runStartedMs: Int64?

    init(enabled: Bool, load: Load, waitingNames: Int, runActive: Bool = false, runStartedMs: Int64? = nil) {
      self.enabled = enabled
      self.load = load
      self.waitingNames = waitingNames
      self.runActive = runActive
      self.runStartedMs = runStartedMs
    }
  }

  struct Memory: Codable, Equatable, Sendable {
    enum Stage: Int, Codable, Sendable { case firstLoad, open, spent }

    var stage: Stage = .firstLoad
    var low = 0
    var importSeen = false
    var wasImporting = false
    var opens = 0
    var lastRunMs: Int64 = 0
  }

  static func observe(_ m: Memory, _ f: Facts) -> Memory {
    var m = m
    if let started = f.runStartedMs, started > m.lastRunMs {
      m.lastRunMs = started
      m.stage = .spent
      m.low = f.waitingNames
      m.importSeen = false
      m.wasImporting = f.load.mailbox == .importing || f.load.mailbox == .awaitingCards
      m.opens = 0
    }
    if m.stage == .spent { m.low = min(m.low, f.waitingNames) }
    return noted(m, f.load.mailbox)
  }

  static func noted(_ m: Memory, _ mailbox: Mailbox) -> Memory {
    var m = m
    let importing = mailbox == .importing || mailbox == .awaitingCards
    if m.stage == .spent, importing, !m.wasImporting { m.importSeen = true }
    if mailbox == .importing { m.opens = 0 }
    m.wasImporting = importing
    return m
  }

  static func opened(_ m: Memory, _ f: Facts) -> Memory {
    var m = observe(m, f)
    switch f.load.mailbox {
    case .awaitingCards, .none: m.opens = min(m.opens + 1, opensBeforeFallback)
    case .active, .elsewhere, .importing: break
    }
    return m
  }

  static func shown(_ m: Memory, _ f: Facts) -> Memory {
    var m = observe(m, f)
    guard due(m, f), m.stage != .open else { return m }
    m.stage = .open
    m.importSeen = false
    m.opens = 0
    return m
  }

  static func loaded(_ m: Memory, _ load: Load) -> Bool {
    switch load.mailbox {
    case .active, .elsewhere: load.caughtUp
    case .importing: false
    case .awaitingCards, .none: load.caughtUp && m.opens >= opensBeforeFallback
    }
  }

  static func due(_ m: Memory, _ f: Facts) -> Bool {
    guard f.enabled, !f.runActive, f.waitingNames >= CloudSortCardState.minimumNames else { return false }
    guard f.load.mailbox != .importing else { return false }
    switch m.stage {
    case .firstLoad:
      return loaded(m, f.load)
    case .open:
      return true
    case .spent:
      return f.waitingNames - m.low >= returningGroups || (m.importSeen && loaded(m, f.load))
    }
  }

  struct Store: Sendable {
    var load: @Sendable () -> Memory
    var save: @Sendable (Memory) -> Void

    static let key = "app.hasala.prefs.cloudSort.runOffer"

    static func live(_ suiteName: String? = nil) -> Store {
      let defaults: @Sendable () -> UserDefaults = { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
      return Store(
        load: {
          guard let data = defaults().data(forKey: key), let m = try? JSONDecoder().decode(Memory.self, from: data) else {
            return Memory()
          }
          return m
        },
        save: { m in
          guard let data = try? JSONEncoder().encode(m) else { return }
          defaults().set(data, forKey: key)
        })
    }

    static func inMemory(_ start: Memory = Memory()) -> Store {
      let box = MemoryBox(start)
      return Store(load: { box.value }, save: { box.value = $0 })
    }

    static func forget(_ defaults: UserDefaults) {
      defaults.removeObject(forKey: key)
    }
  }

  final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Memory

    init(_ m: Memory) { stored = m }

    var value: Memory {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }
}

enum SortSlot: Equatable {
  case ask
  case run(CloudSortCardState)
  case result
  case offer(CloudSortCardState)
  case importing(MailImport)

  struct Facts: Equatable {
    var asks: Bool
    var status: CloudSortStatus?
    var dismissedRun: Int64?
    var importing: MailImport?

    init(asks: Bool = false, status: CloudSortStatus? = nil, dismissedRun: Int64? = nil, importing: MailImport? = nil) {
      self.asks = asks
      self.status = status
      self.dismissedRun = dismissedRun
      self.importing = importing
    }
  }

  static func of(_ f: Facts) -> SortSlot? {
    if f.asks, f.status.map({ $0.phase == .off }) ?? true { return .ask }
    if let status = f.status {
      switch status.phase {
      case .running: return .run(.running)
      case .paused(let p): return .run(.paused(p))
      case .done:
        if let ended = status.lastRunEndedMs, ended != f.dismissedRun { return .result }
      case .off, .idle:
        break
      }
      if status.offerDue, let card = CloudSortCardState.offer(status) { return .offer(card) }
    }
    if let mail = f.importing, mail.showsInSlot { return .importing(mail) }
    return nil
  }

  var card: CloudSortCardState? {
    switch self {
    case .run(let c), .offer(let c): c
    case .result: .done
    case .ask, .importing: nil
    }
  }

  var isOffer: Bool {
    if case .offer(.ready) = self { return true }
    return false
  }

  static func offerSeen(_ slot: SortSlot?, onReview: Bool, phase: ScenePhase, covered: Bool) -> Bool {
    slot?.isOffer == true && onReview && phase == .active && !covered
  }

  struct Foregrounds: Equatable {
    private(set) var left = false

    mutating func note(_ phase: ScenePhase) -> Bool {
      switch phase {
      case .background:
        left = true
        return false
      case .active:
        defer { left = false }
        return left
      default:
        return false
      }
    }
  }

  static func importingTitle(_ mail: MailImport) -> String {
    mail.read > 0 ? "Reading your mail · \(mail.read) so far" : "Reading your mail"
  }

  static func importingLine(_ mail: MailImport, queued: Bool = true) -> String {
    switch mail.state {
    case .offline: "Paused. No internet connection. It continues when you're back online."
    case .paused: "Paused for now. Hasala tries again soon."
    case .reading, .stopped:
      queued
        ? "You can start on the ones here now. More arrive as Hasala reads."
        : "Hasala is reading your bank alerts. Payments to sort show up here."
    }
  }

  static func importingSpoken(_ mail: MailImport, queued: Bool = true) -> String {
    let lead = mail.read > 0 ? "Reading your mail, \(mail.read) so far." : "Reading your mail."
    return "\(lead) \(importingLine(mail, queued: queued))"
  }
}

extension MailImport {
  var showsInSlot: Bool {
    if case .stopped = state { return false }
    return true
  }
}
