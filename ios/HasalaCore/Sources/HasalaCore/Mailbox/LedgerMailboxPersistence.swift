// `MailboxPersistence` over ledger.sqlite (CoreStore's `MailboxTableStore`): the production
// persistence. Each `commit` is one SQLite transaction holding the message's `pending_ops` row(s)
// and its accounting, so the op and the "this message is done" mark can never disagree.
//
// The drafts become ops through `author`, which the composition root supplies from CoreDomain's
// OpAuthor (R5: the only op constructor) and CoreOutbox's canonical-JSON check; this file never
// builds an op itself.
import CoreStore
import Foundation

public typealias MailboxOpAuthor = @Sendable (_ drafts: [MailboxIngestDraft], _ atMs: Int64) throws -> [MailboxPendingOpRow]

public actor LedgerMailboxPersistence: MailboxPersistence {
  let tables: MailboxTableStore
  let author: MailboxOpAuthor
  let nowMs: @Sendable () -> Int64

  public init(tables: MailboxTableStore, author: @escaping MailboxOpAuthor, nowMs: @escaping @Sendable () -> Int64) {
    self.tables = tables
    self.author = author
    self.nowMs = nowMs
  }

  func io<T>(_ body: () throws -> T) throws(MailboxPersistenceError) -> T {
    do { return try body() } catch { throw MailboxPersistenceError(String(describing: type(of: error))) }
  }

  public func loadState() async throws(MailboxPersistenceError) -> MailboxState {
    guard let r = try io({ try tables.loadState() }) else { return MailboxState() }
    var s = MailboxState()
    s.phase = MailboxPhase(rawValue: r.phase) ?? .unlinked
    s.address = r.address
    s.watermarkMs = r.watermarkMs
    s.profileHistoryID = r.profileHistoryID
    s.backfillDays = r.backfillDays
    s.scanStartedMs = r.scanStartedMs
    s.watchExpiresAtMs = r.watchExpiresAt
    s.haltedOn = r.haltedOn.flatMap(MailboxHaltCode.init(rawValue:))
    s.haltedDetail = r.haltedDetail
    s.lastCycleAtMs = r.lastCycleAt
    s.lastSuccessAtMs = r.lastSuccessAt
    s.lastHolderCheckAtMs = r.lastHolderCheckAt
    return s
  }

  public func accounted(among ids: [String]) async throws(MailboxPersistenceError) -> Set<String> {
    try io { try tables.accounted(among: ids) }
  }

  public func staged(limit: Int) async throws(MailboxPersistenceError) -> [ParsedMail] {
    let rows = try io { try tables.staged(limit: limit) }
    let dec = JSONDecoder()
    return try rows.map { (r: MailboxStagingRow) throws(MailboxPersistenceError) -> ParsedMail in
      do { return try dec.decode(ParsedMail.self, from: r.draftJSON) } catch {
        throw MailboxPersistenceError("staging row unreadable")
      }
    }
  }

  public func stagedCount() async throws(MailboxPersistenceError) -> Int { try io { try tables.stagedCount() } }

  public func commit(_ c: MailboxCommit) async throws(MailboxPersistenceError) {
    var w = MailboxWrite()
    w.clearAll = c.clearAll
    w.clearReader = c.clearReader
    if !c.drafts.isEmpty {
      let at = nowMs()
      w.pending = try io { try author(c.drafts, at) }
    }
    w.accounted = c.accounted.map {
      MailboxAccountedRow(messageID: $0.messageID, outcome: $0.outcome.rawValue, internalDate: $0.internalDateMs, at: $0.atMs)
    }
    w.setAside = c.setAside.map {
      MailboxSetAsideRow(messageID: $0.messageID, domain: $0.domain, internalDate: $0.internalDateMs, at: $0.atMs)
    }
    w.unreadable = c.unreadable.map {
      MailboxUnreadableRow(
        messageID: $0.messageID, reason: $0.reason.rawValue, domain: $0.domain, internalDate: $0.internalDateMs, at: $0.atMs)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    w.stage = try c.stage.map { (m: ParsedMail) throws(MailboxPersistenceError) -> MailboxStagingRow in
      do {
        return MailboxStagingRow(
          messageID: m.messageID, ingestID: m.ingestID, bank: m.bank, last4: m.last4,
          gatesJSON: try enc.encode(m.gates), draftJSON: try enc.encode(m), internalDate: m.internalDateMs)
      } catch {
        throw MailboxPersistenceError("staging encode")
      }
    }
    w.unstage = c.unstage
    w.pruneAccountedBelow = c.pruneAccountedBelowMs
    w.addImports = c.addImports.map { ($0.domain, $0.sinceMs) }
    w.doneImports = c.doneImports
    w.unparsedSenders = c.unparsedSenders.map {
      MailboxUnparsedSenderRow(messageID: $0.messageID, domain: $0.domain, at: $0.atMs)
    }
    w.reader = c.reader?.encoded()
    w.health = c.healthBumps.map { ($0.domain, MailboxClock.localMonth($0.internalDateMs), $0.internalDateMs) }
    if let s = c.state {
      var r = MailboxStateRow(phase: s.phase.rawValue)
      r.address = s.address
      r.watermarkMs = s.watermarkMs
      r.profileHistoryID = s.profileHistoryID
      r.backfillDays = s.backfillDays
      r.scanStartedMs = s.scanStartedMs
      r.watchExpiresAt = s.watchExpiresAtMs
      r.haltedOn = s.haltedOn?.rawValue
      r.haltedDetail = s.haltedDetail
      r.lastCycleAt = s.lastCycleAtMs
      r.lastSuccessAt = s.lastSuccessAtMs
      r.lastHolderCheckAt = s.lastHolderCheckAtMs
      w.state = r
    }
    let write = w
    try io { try tables.commit(write) }
  }

  public func setAsideRecords() async throws(MailboxPersistenceError) -> [SetAsideRecord] {
    try io { try tables.setAside() }.map {
      SetAsideRecord(messageID: $0.messageID, domain: $0.domain, internalDateMs: $0.internalDate, atMs: $0.at)
    }
  }

  public func unreadableRecords() async throws(MailboxPersistenceError) -> [UnreadableRecord] {
    try io { try tables.unreadable() }.map {
      UnreadableRecord(
        messageID: $0.messageID, reason: UnreadableReason(rawValue: $0.reason) ?? .undecodable, domain: $0.domain,
        internalDateMs: $0.internalDate, atMs: $0.at)
    }
  }

  public func loadReader() async throws(MailboxPersistenceError) -> MailReaderState? {
    MailReaderState.decoded(try io { try tables.loadReader() })
  }

  public func unparsedSenders() async throws(MailboxPersistenceError) -> [String: String] {
    try io { try tables.unparsedSenders() }
  }

  public func isParsing(_ messageID: String) async throws(MailboxPersistenceError) -> Bool {
    try io { try tables.isParsing(messageID) }
  }

  public func markParsing(_ messageID: String) async throws(MailboxPersistenceError) {
    let at = nowMs()
    try io { try tables.markParsing(messageID, at: at) }
  }

  public func clearParsing(_ messageID: String) async throws(MailboxPersistenceError) {
    try io { try tables.clearParsing(messageID) }
  }

  public func pendingImports() async throws(MailboxPersistenceError) -> [PendingImport] {
    try io { try tables.pendingImports() }.map { PendingImport(domain: $0.domain, sinceMs: $0.sinceMs) }
  }

  public func senderAddresses() async throws(MailboxPersistenceError) -> [String] {
    try io { try tables.senderAddresses() }
  }

  public func addSenderAddress(_ address: String) async throws(MailboxPersistenceError) {
    let at = nowMs()
    try io { try tables.addSenderAddress(address, at: at) }
  }

  public func bankHealth() async throws(MailboxPersistenceError) -> [BankHealthRow] {
    try io { try tables.bankHealth() }.map {
      BankHealthRow(domain: $0.domain, lastEmailAtMs: $0.lastEmailAt, month: $0.month, readThisMonth: $0.readThisMonth)
    }
  }
}
