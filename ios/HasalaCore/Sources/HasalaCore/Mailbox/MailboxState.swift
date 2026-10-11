// The device-local mailbox state (spec 04 §4.2: `mailbox_state`, `mailbox_accounted`,
// `mailbox_set_aside`, `mailbox_unreadable`, `mailbox_staging`, `bank_health`) and the ports the
// engine reaches the rest of the app through.
//
// Persistence is a port, not GRDB: CoreMailbox may not import GRDB (spec 04 §2.4 R6). CoreStore
// implements `MailboxPersistence` over `ledger.sqlite`, where `pending_ops` lives too, so that
// `commit` can write a message's op AND its accounting row in ONE transaction (§7.5 step 7f).
// `InMemoryMailboxPersistence` is the reference implementation the tests run against.
import CoreJSON
import CoreTime
import Foundation

public enum MailboxPhase: String, Sendable, Codable, CaseIterable {
  case unlinked, scanning
  case awaitingCards = "awaiting_cards"
  case authoringBackfill = "authoring_backfill"
  case active
  case otherDevice = "other_device"
  case reconnectRequired = "reconnect_required"
  case halted
}

/// Content-free error codes (spec 04 §7.11).
public enum MailboxHaltCode: String, Sendable, Codable {
  case reconnectRequired = "reconnect_required"
  case notHolder = "not_holder"
  case accountFull = "account_full"
  case quota
  case templatesUnavailable = "templates_unavailable"
  case stagingFull = "staging_full"
  case offline
  case gmail
}

/// The `mailbox_state` row, column for column (§4.2; `list_page_token` is not kept: a listing
/// never resumes across runs, the accounted set makes the re-list cheap).
public struct MailboxState: Sendable, Equatable, Codable {
  public var phase: MailboxPhase = .unlinked
  /// The Gmail address from the id_token; shown on Bank alerts. Device-local only.
  public var address: String?
  /// Every message of the sender-filtered listing with internalDate < watermark − OVERLAP is
  /// accounted (the checkpoint, PO G).
  public var watermarkMs: Int64?
  /// A change detector only (§7.5 step 6).
  public var profileHistoryID: String?
  public var backfillDays: Int?
  public var scanStartedMs: Int64?
  public var watchExpiresAtMs: Int64?
  public var haltedOn: MailboxHaltCode?
  public var haltedDetail: String?
  public var lastCycleAtMs: Int64?
  public var lastSuccessAtMs: Int64?
  public var lastHolderCheckAtMs: Int64?
  public init() {}
}

public enum AccountedOutcome: String, Sendable, Codable {
  case op
  case setAside = "set_aside"
  case unreadable, dup, gone
}

public struct AccountedRecord: Sendable, Equatable, Codable {
  public var messageID: String
  public var outcome: AccountedOutcome
  public var internalDateMs: Int64
  public var atMs: Int64
}

public struct SetAsideRecord: Sendable, Equatable, Codable {
  public var messageID: String
  public var domain: String
  public var internalDateMs: Int64
  public var atMs: Int64
}

public enum UnreadableReason: String, Sendable, Codable {
  case undecodable
  case overCap = "over_cap"
  case badDate = "bad_date"
  case gone
}

public struct UnreadableRecord: Sendable, Equatable, Codable {
  public var messageID: String
  public var reason: UnreadableReason
  public var domain: String?
  public var internalDateMs: Int64?
  public var atMs: Int64
}

public struct BankHealthRow: Sendable, Equatable, Codable {
  public var domain: String
  public var lastEmailAtMs: Int64?
  /// `YYYY-MM` (local month).
  public var month: String
  public var readThisMonth: Int
}

/// Everything one engine step writes, in one transaction.
public struct MailboxCommit: Sendable {
  /// Authored as `txn_ingested` ops (OpAuthor) and enqueued in `pending_ops`.
  public var drafts: [MailboxIngestDraft] = []
  public var accounted: [AccountedRecord] = []
  public var setAside: [SetAsideRecord] = []
  public var unreadable: [UnreadableRecord] = []
  public var stage: [ParsedMail] = []
  public var unstage: [String] = []
  /// Delete accounted rows with internal_date below this (ms).
  public var pruneAccountedBelowMs: Int64?
  /// Count one read message for its domain's `bank_health` (domain, internalDate).
  public var healthBumps: [(domain: String, internalDateMs: Int64)] = []
  /// Replaces the state row when set.
  public var state: MailboxState?
  /// Clears every mailbox table (Disconnect).
  public var clearAll = false

  public init() {}
  public var isEmpty: Bool {
    drafts.isEmpty && accounted.isEmpty && setAside.isEmpty && unreadable.isEmpty && stage.isEmpty
      && unstage.isEmpty && pruneAccountedBelowMs == nil && healthBumps.isEmpty && state == nil && !clearAll
  }
}

public struct MailboxPersistenceError: Error, Sendable, Equatable {
  public let detail: String
  public init(_ detail: String) { self.detail = detail }
}

public protocol MailboxPersistence: Sendable {
  func loadState() async throws(MailboxPersistenceError) -> MailboxState
  /// Which of `ids` already have an accounted row (or a staging row).
  func accounted(among ids: [String]) async throws(MailboxPersistenceError) -> Set<String>
  /// The staged scan results, oldest internalDate first.
  func staged(limit: Int) async throws(MailboxPersistenceError) -> [ParsedMail]
  func stagedCount() async throws(MailboxPersistenceError) -> Int
  /// One transaction: ops enqueued, accounting, set-aside, unreadable, staging, health, state.
  func commit(_ c: MailboxCommit) async throws(MailboxPersistenceError)
  func setAsideRecords() async throws(MailboxPersistenceError) -> [SetAsideRecord]
  func unreadableRecords() async throws(MailboxPersistenceError) -> [UnreadableRecord]
  func bankHealth() async throws(MailboxPersistenceError) -> [BankHealthRow]
}

/// The reference `MailboxPersistence`: the semantics a GRDB implementation must keep, in memory.
/// Rings: set-aside keeps the newest 200, unreadable the newest 50 (§4.2).
public actor InMemoryMailboxPersistence: MailboxPersistence {
  public private(set) var state = MailboxState()
  public private(set) var accountedRows: [String: AccountedRecord] = [:]
  public private(set) var setAside: [SetAsideRecord] = []
  public private(set) var unreadable: [UnreadableRecord] = []
  public private(set) var staging: [String: ParsedMail] = [:]
  public private(set) var health: [String: BankHealthRow] = [:]
  /// Drafts enqueued, in order (the tests' view of `pending_ops`).
  public private(set) var enqueued: [MailboxIngestDraft] = []
  /// Fails the next commit (tests: a crash between steps).
  public var failNextCommit = false

  public static let setAsideRing = 200
  public static let unreadableRing = 50

  public init(state: MailboxState = MailboxState()) { self.state = state }

  public func setFailNextCommit(_ v: Bool) { failNextCommit = v }

  public func loadState() async throws(MailboxPersistenceError) -> MailboxState { state }

  public func accounted(among ids: [String]) async throws(MailboxPersistenceError) -> Set<String> {
    Set(ids.filter { accountedRows[$0] != nil || staging[$0] != nil })
  }

  public func staged(limit: Int) async throws(MailboxPersistenceError) -> [ParsedMail] {
    Array(
      staging.values.sorted { ($0.internalDateMs, $0.messageID) < ($1.internalDateMs, $1.messageID) }.prefix(limit))
  }

  public func stagedCount() async throws(MailboxPersistenceError) -> Int { staging.count }

  public func commit(_ c: MailboxCommit) async throws(MailboxPersistenceError) {
    if failNextCommit {
      failNextCommit = false
      throw MailboxPersistenceError("injected")
    }
    if c.clearAll {
      accountedRows = [:]
      setAside = []
      unreadable = []
      staging = [:]
      health = [:]
    }
    enqueued.append(contentsOf: c.drafts)
    for a in c.accounted { accountedRows[a.messageID] = a }
    for s in c.setAside where !setAside.contains(where: { $0.messageID == s.messageID }) { setAside.append(s) }
    setAside = Array(setAside.sorted { $0.internalDateMs > $1.internalDateMs }.prefix(Self.setAsideRing))
    for u in c.unreadable {
      unreadable.removeAll { $0.messageID == u.messageID }
      unreadable.append(u)
    }
    unreadable = Array(unreadable.sorted { $0.atMs > $1.atMs }.prefix(Self.unreadableRing))
    for s in c.stage { staging[s.messageID] = s }
    for id in c.unstage { staging[id] = nil }
    if let below = c.pruneAccountedBelowMs { accountedRows = accountedRows.filter { $0.value.internalDateMs >= below } }
    for b in c.healthBumps {
      let month = MailboxClock.localMonth(b.internalDateMs)
      var row = health[b.domain] ?? BankHealthRow(domain: b.domain, lastEmailAtMs: nil, month: month, readThisMonth: 0)
      if row.month != month {
        if month > row.month {
          row.month = month
          row.readThisMonth = 0
        }
      }
      if row.month == month { row.readThisMonth += 1 }
      row.lastEmailAtMs = max(row.lastEmailAtMs ?? 0, b.internalDateMs)
      health[b.domain] = row
    }
    if let s = c.state { state = s }
  }

  public func setAsideRecords() async throws(MailboxPersistenceError) -> [SetAsideRecord] { setAside }
  public func unreadableRecords() async throws(MailboxPersistenceError) -> [UnreadableRecord] { unreadable }
  public func bankHealth() async throws(MailboxPersistenceError) -> [BankHealthRow] {
    health.values.sorted { $0.domain < $1.domain }
  }
}

enum MailboxClock {
  /// `YYYY-MM` of the instant's local (+04:00) month.
  static func localMonth(_ ms: Int64) -> String {
    LocalClock.localMonth(ms)?.description ?? "0000-01"
  }
}
