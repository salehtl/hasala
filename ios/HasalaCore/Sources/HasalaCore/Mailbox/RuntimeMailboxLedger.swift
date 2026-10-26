// The production `MailboxLedger` (spec 04 §7.5, §3): the Gmail lane's view of
// the account's ledger, over the same sync engine, observer, outbox and
// projection the screens use.
//
//   syncToHead       a `refresh` run: reconcile, pull (fold + project), flush
//   senderTrust      the projection's `sender_trust` (pending overlay included)
//   knownCards       the projection's `card` links
//   projectedMessageIDs / isIngested   the projection, plus pending ops for ingest ids
//   authorCards      `account_set` (when the card's account is new) + `card_linked`, one blob
//   authorSenderTrust `sender_trust_set` through OpAuthor's typed-input rules
//   flush            an `authored` run, mapped onto `FlushOutcome`
//
// Authored blobs go through the Outbox (durable before the call returns), then
// the observer re-projects so the next read sees them at once.
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreStore
import CoreSync
import Foundation

public actor RuntimeMailboxLedger: MailboxLedger {
  let engine: SyncEngine
  let observer: LedgerPageObserver
  let outbox: Outbox
  /// The persistence's op author; its stamps follow this ledger's pulls.
  public let authoring: MailboxAuthoring

  /// Display names for accounts created from a card ("<Bank> ···<last4>", 03b §4.2 table).
  public static let bankNames: [String: String] = ["enbd": "Emirates NBD", "dib": "DIB", "adib": "ADIB"]

  /// `authoring` must be the one given to `LedgerMailboxPersistence`, built
  /// with `MailboxAuthoring(observer:)` so it shares the observer's stamps.
  public init(engine: SyncEngine, observer: LedgerPageObserver, outbox: Outbox, authoring: MailboxAuthoring) {
    self.engine = engine
    self.observer = observer
    self.outbox = outbox
    self.authoring = authoring
  }

  var reader: LedgerReader { observer.reader }

  public func syncToHead() async throws(MailboxLedgerError) {
    let out = await engine.run(.refresh)
    if let stop = out.stop, !Self.tolerable(stop) {
      throw MailboxLedgerError("sync_\(Self.code(stop))")
    }
    if let seen = try? await observer.seenStamps() { authoring.updateSeen(seen) }
  }

  public func senderTrust() async -> [String: Bool] { (try? reader.senderTrust()) ?? [:] }

  public func knownCards() async -> [CardKey: CardState] {
    var out: [CardKey: CardState] = [:]
    for c in (try? reader.cards()) ?? [] {
      guard let s = CardState(rawValue: c.state) else { continue }
      out[CardKey(bank: c.bank ?? "", last4: c.last4)] = s
    }
    return out
  }

  public func projectedMessageIDs(among ids: [String]) async -> Set<String> {
    (try? reader.knownMailboxMessageIDs(ids)) ?? []
  }

  public func isIngested(_ ingestID: String) async -> Bool {
    if (try? reader.hasIngest(ingestID)) == true { return true }
    return (try? observer.context.store.hasPendingIngest(ingestID)) == true
  }

  public func authorCards(_ decisions: [CardDecision]) async throws(MailboxLedgerError) {
    guard !decisions.isEmpty else { return }
    let accounts = Set(((try? reader.accounts()) ?? []).map(\.id))
    let current = await knownCards()
    let cardTemplates = stagedCardTemplates()
    try await author { a throws(AuthorError) in
      var created: Set<String> = []
      for d in decisions {
        let bank: String? = d.card.bank.isEmpty ? nil : d.card.bank
        switch d.state {
        case .mine:
          let account = d.accountID ?? OpAuthor.cardAccountID(bank: bank, last4: d.card.last4)
          if current[d.card] == .mine, d.accountID == nil { continue }  // 03b `.cardAlreadyMine`
          if !accounts.contains(account), !created.contains(account) {
            let name = "\(bank.map { Self.bankNames[$0] ?? $0.uppercased() } ?? "Card") ···\(d.card.last4)"
            let kind: OpAuthor.AccountKind = cardTemplates.contains(d.card) ? .creditCard : .current
            try a.setAccount(id: account, OpAuthor.AccountDraft(name: name, institution: bank, kind: kind))
            created.insert(account)
          }
          a.linkCard(bank: bank, last4: d.card.last4, .mine(account: account))
        case .notMine:
          if current[d.card] == .notMine { continue }
          a.linkCard(bank: bank, last4: d.card.last4, .notMine)
        }
      }
    }
  }

  public func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError) {
    let current = BankDomains.effectiveTrusted(await senderTrust())
    try await author { a throws(AuthorError) in
      try a.setSenderTrust(typed: domain, trusted: trusted, currentTrusted: current)
    }
  }

  public func retirePlan(grantID: String, provider: String) async -> MailboxRetirePlan {
    let legacy = ((try? reader.otherMailboxCount(grantID: grantID, provider: provider)) ?? 1) == 0
    guard let counts = try? reader.mailboxImports(grantID: grantID, provider: provider, legacy: legacy) else {
      return MailboxRetirePlan(grantID: grantID, provider: provider, legacy: legacy, total: 0, edited: 0, countKnown: false)
    }
    return MailboxRetirePlan(grantID: grantID, provider: provider, legacy: legacy, total: counts.total, edited: counts.edited)
  }

  public func authorRetire(_ plan: MailboxRetirePlan) async throws(MailboxLedgerError) {
    try await author { a throws(AuthorError) in
      a.retireMailbox(grantID: plan.grantID, provider: plan.provider, legacy: plan.legacy)
    }
  }

  public func flush() async -> FlushOutcome {
    let out = await engine.run(.authored)
    if await engine.status.latch == .accountFull { return .accountFull }
    if case .latched(.accountFull, _)? = out.stop { return .accountFull }
    guard out.stop == nil else { return .failed }
    return (try? observer.context.store.pendingCount()) == 0 ? .flushed : .failed
  }

  /// The cards whose staged alerts a card template read (`<bank>.card.*`): their
  /// new account is a credit card, the others current accounts (03b §4.2).
  func stagedCardTemplates() -> Set<CardKey> {
    let rows = (try? MailboxTableStore(writer: observer.context.store.db).staged(limit: 10_000)) ?? []
    var out: Set<CardKey> = []
    for r in rows {
      guard let g = try? JSONDecoder().decode(MailGates.self, from: r.gatesJSON), let t = g.template,
        t.hasPrefix("\(r.bank).card.")
      else { continue }
      out.insert(CardKey(bank: r.bank, last4: r.last4))
    }
    return out
  }

  /// Builds one blob with `body` (under the account's shared stamps),
  /// enqueues it and re-projects.
  func author(_ body: (inout OpAuthor) throws(AuthorError) -> Void) async throws(MailboxLedgerError) {
    let ctx: AuthorContext
    do { ctx = try await observer.authorContext() } catch { throw MailboxLedgerError("context_\(Self.code(error))") }
    let built: AuthoredBlob?
    do { built = try observer.stamps.build(ctx, body) } catch { throw MailboxLedgerError(Self.code(error)) }
    guard let blob = built else { return }
    do { try await outbox.enqueue(blob.ops) } catch { throw MailboxLedgerError("enqueue") }
    try? await observer.reproject()
  }

  /// A stop the lane may read through: the pull reached what it could and the
  /// projection is the last good one (rate limits, a latched outbox).
  static func tolerable(_ stop: SyncStop) -> Bool {
    switch stop {
    case .rateLimited, .latched, .suspended: return true
    default: return false
    }
  }

  static func code(_ stop: SyncStop) -> String {
    switch stop {
    case .offline, .protocolError: "offline"
    case .rateLimited: "rate_limited"
    case .halted: "halted"
    case .latched: "latched"
    case .frozen: "frozen"
    case .needsSignIn: "needs_sign_in"
    case .needsRebind: "needs_rebind"
    case .needsUnlock: "needs_unlock"
    case .keysRequired: "keys_required"
    case .wipe: "wipe"
    case .suspended: "suspended"
    case .notNow: "not_now"
    case .store: "store"
    case .cancelled: "cancelled"
    }
  }

  static func code(_ e: AuthorError) -> String {
    switch e {
    case .invalidOp: "invalid_op"
    case .opTooLarge: "op_too_large"
    case .refused(let r): "refused_\(r)"
    case .random: "random"
    }
  }
}
