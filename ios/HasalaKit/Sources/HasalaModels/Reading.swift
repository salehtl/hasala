import Foundation

public struct ReadingFacts: Sendable, Hashable, Codable {
  public enum LanePhase: String, Sendable, Hashable, Codable {
    case unlinked, scanning, backfill, active, otherDevice, reconnectRequired, halted
  }

  public enum Halt: String, Sendable, Hashable, Codable {
    case signIn, noMailbox, accountFull, templates, quota, provider, other
  }

  public struct Mail: Sendable, Hashable, Codable {
    public var provider: MailProviderKind
    public var phase: LanePhase
    public var halt: Halt?
    public var lastCheckedMs: Int64?
    public var connectedMs: Int64?
    public var pastSkippedFromMs: Int64?
    public var importRead: Int
    public var importTotal: Int
    public var importOffline: Bool
    public var importPaused: Bool
    public var thisMonthRead: Bool

    public init(
      provider: MailProviderKind, phase: LanePhase, halt: Halt? = nil, lastCheckedMs: Int64? = nil,
      connectedMs: Int64? = nil, pastSkippedFromMs: Int64? = nil, importRead: Int = 0, importTotal: Int = 0,
      importOffline: Bool = false, importPaused: Bool = false, thisMonthRead: Bool = false
    ) {
      self.provider = provider
      self.phase = phase
      self.halt = halt
      self.lastCheckedMs = lastCheckedMs
      self.connectedMs = connectedMs
      self.pastSkippedFromMs = pastSkippedFromMs
      self.importRead = importRead
      self.importTotal = importTotal
      self.importOffline = importOffline
      self.importPaused = importPaused
      self.thisMonthRead = thisMonthRead
    }
  }

  public struct Bank: Sendable, Hashable, Codable {
    public var name: String
    public var lastMailMs: Int64?

    public init(name: String, lastMailMs: Int64?) {
      self.name = name
      self.lastMailMs = lastMailMs
    }
  }

  public struct Texts: Sendable, Hashable, Codable {
    public var lastRunMs: Int64?
    public var testMissed: Bool

    public init(lastRunMs: Int64? = nil, testMissed: Bool = false) {
      self.lastRunMs = lastRunMs
      self.testMissed = testMissed
    }
  }

  public var nowMs: Int64
  public var known: Bool
  public var sample: Bool
  public var mail: Mail?
  public var heldElsewhere: MailProviderKind?
  public var texts: Texts?
  public var banks: [Bank]
  public var newestMailRowMs: Int64?
  public var earliestBankRow: LocalDate?
  public var backgroundRefreshOff: Bool
  public var movedAwayMs: Int64?

  public init(
    nowMs: Int64, known: Bool = true, sample: Bool = false, mail: Mail? = nil, heldElsewhere: MailProviderKind? = nil,
    texts: Texts? = nil, banks: [Bank] = [], newestMailRowMs: Int64? = nil, earliestBankRow: LocalDate? = nil,
    backgroundRefreshOff: Bool = false, movedAwayMs: Int64? = nil
  ) {
    self.nowMs = nowMs
    self.known = known
    self.sample = sample
    self.mail = mail
    self.heldElsewhere = heldElsewhere
    self.texts = texts
    self.banks = banks
    self.newestMailRowMs = newestMailRowMs
    self.earliestBankRow = earliestBankRow
    self.backgroundRefreshOff = backgroundRefreshOff
    self.movedAwayMs = movedAwayMs
  }
}

public struct ReadingThresholds: Sendable, Hashable, Codable {
  public var behindAfterMs: Int64
  public var quietAfterDays: Int
  public var elsewhereStaleDays: Int

  public init(behindAfterMs: Int64 = 24 * 3_600_000, quietAfterDays: Int = 14, elsewhereStaleDays: Int = 7) {
    self.behindAfterMs = behindAfterMs
    self.quietAfterDays = quietAfterDays
    self.elsewhereStaleDays = elsewhereStaleDays
  }

  public static let standard = ReadingThresholds()
}

public struct ReadingState: Sendable, Hashable, Codable {
  public enum Source: Sendable, Hashable, Codable {
    case none
    case mail(MailProviderKind)
    case texts
  }

  public enum StopReason: String, Sendable, Hashable, Codable {
    case signInAgain
    case noMailbox
    case accountFull
    case other
  }

  public enum Kind: Sendable, Hashable, Codable {
    case checking
    case sample
    case off
    case working
    case waitingForFirstText
    case textTestMissed
    case importing(read: Int, total: Int, thisMonthRead: Bool, offline: Bool, paused: Bool)
    case stopped(StopReason, since: LocalDate?)
    case behind(since: LocalDate, backgroundRefreshOff: Bool)
    case quiet(banks: [String])
    case elsewhere(newest: LocalDate?, stale: Bool, canTakeOver: Bool)
  }

  public var source: Source
  public var kind: Kind
  public var lastCheckedMs: Int64?
  public var readsFrom: LocalDate?
  public var readsFromExact: Bool
  public var movedAway: Bool
  public var today: LocalDate

  public init(
    source: Source, kind: Kind, lastCheckedMs: Int64? = nil, readsFrom: LocalDate? = nil, readsFromExact: Bool = false,
    movedAway: Bool = false, today: LocalDate
  ) {
    self.source = source
    self.kind = kind
    self.lastCheckedMs = lastCheckedMs
    self.readsFrom = readsFrom
    self.readsFromExact = readsFromExact
    self.movedAway = movedAway
    self.today = today
  }

  public static let localOffsetMs: Int64 = 4 * 3_600_000

  public static func localDay(_ ms: Int64) -> LocalDate {
    let shifted = ms + localOffsetMs
    let day = shifted >= 0 ? shifted / 86_400_000 : (shifted - 86_399_999) / 86_400_000
    return LocalDate(ordinal: Int(day))
  }

  public static func derive(_ f: ReadingFacts, thresholds t: ReadingThresholds = .standard) -> ReadingState {
    let today = localDay(f.nowMs)
    let source = Self.source(f)
    var state = ReadingState(
      source: source, kind: .off, lastCheckedMs: f.mail?.lastCheckedMs, readsFrom: nil, readsFromExact: false,
      movedAway: f.movedAwayMs != nil, today: today)
    if let skipped = f.mail?.pastSkippedFromMs, f.mail?.phase == .active {
      state.readsFrom = localDay(skipped)
      state.readsFromExact = true
    } else if source != .none, let earliest = f.earliestBankRow {
      state.readsFrom = earliest
    }
    state.kind = kind(f, t, today: today)
    return state
  }

  static func source(_ f: ReadingFacts) -> Source {
    if let m = f.mail, m.phase != .unlinked { return .mail(m.provider) }
    if let held = f.heldElsewhere { return .mail(held) }
    if f.texts != nil { return .texts }
    return .none
  }

  static func kind(_ f: ReadingFacts, _ t: ReadingThresholds, today: LocalDate) -> Kind {
    guard f.known else { return .checking }
    if f.sample { return .sample }
    let since = f.mail?.lastCheckedMs.map(localDay)
    if let m = f.mail {
      switch m.phase {
      case .reconnectRequired:
        return .stopped(.signInAgain, since: since)
      case .halted:
        return .stopped(stopReason(m.halt), since: since)
      case .scanning, .backfill:
        return .importing(
          read: min(m.importRead, m.importTotal), total: m.importTotal, thisMonthRead: m.thisMonthRead,
          offline: m.importOffline, paused: m.importPaused)
      case .otherDevice:
        return elsewhere(f, t, today: today, canTakeOver: false)
      case .active:
        return active(f, m, t, today: today)
      case .unlinked:
        break
      }
    }
    if f.heldElsewhere != nil { return elsewhere(f, t, today: today, canTakeOver: true) }
    if let texts = f.texts {
      if texts.lastRunMs == nil { return texts.testMissed ? .textTestMissed : .waitingForFirstText }
      return .working
    }
    return .off
  }

  static func stopReason(_ halt: ReadingFacts.Halt?) -> StopReason {
    switch halt {
    case .signIn?: .signInAgain
    case .noMailbox?: .noMailbox
    case .accountFull?: .accountFull
    case .templates?, .quota?, .provider?, .other?, nil: .other
    }
  }

  static func elsewhere(_ f: ReadingFacts, _ t: ReadingThresholds, today: LocalDate, canTakeOver: Bool) -> Kind {
    let newest = f.newestMailRowMs.map(localDay)
    let stale = newest.map { $0.days(until: today) >= t.elsewhereStaleDays } ?? true
    return .elsewhere(newest: newest, stale: stale, canTakeOver: canTakeOver)
  }

  static func active(_ f: ReadingFacts, _ m: ReadingFacts.Mail, _ t: ReadingThresholds, today: LocalDate) -> Kind {
    if let last = m.lastCheckedMs, f.nowMs - last >= t.behindAfterMs {
      return .behind(since: localDay(last), backgroundRefreshOff: f.backgroundRefreshOff)
    }
    guard let connected = m.connectedMs, localDay(connected).days(until: today) >= t.quietAfterDays else {
      return .working
    }
    let quiet = f.banks.filter { bank in
      guard let last = bank.lastMailMs else { return true }
      return localDay(last).days(until: today) >= t.quietAfterDays
    }.map(\.name)
    return quiet.isEmpty ? .working : .quiet(banks: quiet)
  }
}

extension ReadingState {
  public var stopped: Bool {
    if case .stopped = kind { return true }
    return false
  }

  public var importing: Bool {
    if case .importing = kind { return true }
    return false
  }

  public var thisMonthUnfinished: Bool {
    if case .importing(_, _, let done, _, _) = kind { return !done }
    return false
  }

  public var elsewhereStale: Bool {
    if case .elsewhere(_, let stale, _) = kind { return stale }
    return false
  }

  public var countedThrough: LocalDate? {
    switch kind {
    case .stopped(_, let since): since
    case .elsewhere(let newest, true, _): newest
    default: nil
    }
  }

  public var countsAreCurrent: Bool {
    switch kind {
    case .stopped, .checking: false
    case .importing(_, _, let done, _, _): done
    case .elsewhere(_, let stale, _): !stale
    case .sample, .off, .working, .waitingForFirstText, .textTestMissed, .behind, .quiet: true
    }
  }

  public func isPartlyRead(_ month: YearMonth) -> Bool {
    guard let from = readsFrom else { return false }
    return from.yearMonth == month && from.day > 1
  }

  public func isBeforeReading(_ month: YearMonth) -> Bool {
    guard let from = readsFrom else { return false }
    return month < from.yearMonth
  }

  public func holdsVerdict(_ month: YearMonth) -> Bool {
    if isPartlyRead(month) || isBeforeReading(month) { return true }
    if month >= today.yearMonth { return !countsAreCurrent }
    guard let through = countedThrough, !countsAreCurrent else { return false }
    return month >= through.yearMonth
  }

  public func isComplete(_ month: YearMonth) -> Bool {
    if isPartlyRead(month) || isBeforeReading(month) { return false }
    if month >= today.yearMonth || importing { return false }
    if let through = countedThrough, !countsAreCurrent { return month < through.yearMonth }
    return true
  }

  public var holdsLateBills: Bool {
    stopped || thisMonthUnfinished || elsewhereStale
  }

  public var needsYou: Bool {
    switch kind {
    case .stopped, .quiet, .textTestMissed: true
    case .elsewhere(_, let stale, _): stale
    case .checking, .sample, .off, .working, .waitingForFirstText, .importing, .behind: false
    }
  }
}
