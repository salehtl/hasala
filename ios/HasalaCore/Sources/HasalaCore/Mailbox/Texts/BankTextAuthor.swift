import CoreDomain
import CoreExtract
import CoreTemplate
import CoreTime
import Foundation

public protocol BankTextLedger: Sendable {
  func knownCards() async -> [CardKey: CardState]
  func isIngested(_ ingestID: String) async -> Bool
  func textRows(postedFromMs: Int64, toMs: Int64) async -> [BankTextRow]
  func authorText(_ draft: BankTextDraft, archiving: String?) async throws(MailboxLedgerError) -> String
}

public protocol BankTextLayoutStore: Sendable {
  func load() async -> LearnedLayouts
  func save(_ layouts: LearnedLayouts) async
}

public actor MemoryBankTextLayouts: BankTextLayoutStore {
  private var layouts: LearnedLayouts

  public init(_ layouts: LearnedLayouts = LearnedLayouts()) { self.layouts = layouts }

  public func load() -> LearnedLayouts { layouts }
  public func save(_ layouts: LearnedLayouts) { self.layouts = layouts }
}

public struct BankTextAdded: Sendable, Equatable {
  public var txnID: String
  public var bank: String?
  public var keptAtMs: Int64
  public var filed: Bool
  public var unparsed: Bool
  public var repeatNumber: Int
  public var transferPartner: String?
}

public enum BankTextOutcome: Sendable, Equatable {
  case testPassed
  case dropped(TextDropKind, counted: Bool, bank: String?)
  case ignored(counted: Bool, bank: String?)
  case added(BankTextAdded)
  case failed(String)
}

public actor BankTextAuthor {
  public static let maxRepeats = 1_000

  let ledger: any BankTextLedger
  let layouts: any BankTextLayoutStore
  let categorizer: any IngestCategorizer
  let templates: [CompiledTemplate]
  let serial = WriteSerial()

  public init(
    ledger: any BankTextLedger, layouts: any BankTextLayoutStore = MemoryBankTextLayouts(),
    categorizer: any IngestCategorizer = NoCategorizer(), templates: [CompiledTemplate] = BankTextReader.templates
  ) {
    self.ledger = ledger
    self.layouts = layouts
    self.categorizer = categorizer
    self.templates = templates
  }

  public nonisolated func add(
    _ arrival: BankTextArrival, secret: Data, link: @escaping @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    await run(arrival, origin: .automation, secret: secret, archiving: nil, link: link)
  }

  public nonisolated func paste(
    _ text: String, atMs: Int64, secret: Data, link: BankTextLink, replacing unparsedRowID: String? = nil
  ) async -> BankTextOutcome {
    await run(
      BankTextArrival(text: text, sender: nil, receivedAtMs: atMs), origin: .paste, secret: secret, archiving: unparsedRowID,
      link: { link })
  }

  private nonisolated func run(
    _ arrival: BankTextArrival, origin: BankTextOrigin, secret: Data, archiving: String?,
    link: @escaping @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    guard secret.count == BankTextKey.secretBytes else { return .failed("secret") }
    do {
      return try await serial.run { await self.serialized(arrival, origin: origin, secret: secret, archiving: archiving, link: link) }
    } catch {
      return .failed("serial")
    }
  }

  private func serialized(
    _ arrival: BankTextArrival, origin: BankTextOrigin, secret: Data, archiving: String?,
    link: @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    let memory = await layouts.load()
    let (reading, next) = BankTextReader.read(arrival, templates: templates, layouts: memory)
    if Task.isCancelled { return .failed("cancelled") }
    let kept: BankTextKept
    switch reading {
    case .setUpTest: return .testPassed
    case .dropped(let k, let counted, let bank): return .dropped(k, counted: counted, bank: bank)
    case .kept(let k): kept = k
    }
    let state = await link()
    if state == .linked { return .ignored(counted: kept.countsAsPayment, bank: kept.bank) }
    if Task.isCancelled { return .failed("cancelled") }

    let sender = BankTextReader.sender(arrival.sender, templates: templates)
    let text = BankTextReader.normalized(arrival.text)
    let minute = arrival.arrivalMinuteMs
    var key: (id: String, n: Int)?
    for n in 0..<Self.maxRepeats {
      guard let id = BankTextKey.ingestID(secret: secret, sender: sender.id, normalizedText: text, arrivalMinuteMs: minute, n: n)
      else { return .failed("secret") }
      if await !ledger.isIngested(id) {
        key = (id, n)
        break
      }
    }
    guard let key else { return .failed("repeats") }

    var partner: BankTextRow?
    if let f = kept.fields, let posted = try? parseInstantMs(f.postedAt) {
      let row = BankTextRow(
        id: "", bank: kept.bank, amountMinor: f.amountMinor, currency: f.currency, direction: f.direction, last4: f.last4,
        postedMs: posted, templateRef: kept.template?.ref, unparsed: false)
      if row.transferRole != nil {
        let rows = await ledger.textRows(
          postedFromMs: posted - BankTextTransferPair.windowMs, toMs: posted + BankTextTransferPair.windowMs)
        partner = BankTextTransferPair.partner(of: row, among: rows)
      }
    }
    let cards = await ledger.knownCards()
    let draft = BankTextPayload.build(
      kept, ingestID: key.id, receivedMinuteMs: minute, cards: cards, link: state, origin: origin,
      transferPartner: partner != nil, categorizer: categorizer)
    let card = BankTextPayload.card(kept, cards: cards)
    var txnID: String?
    var authored = draft
    var lastError = "author"
    for d in [draft] + BankTextPayload.fallbacks(draft, kept, card: card, receivedMinuteMs: minute) {
      do throws(MailboxLedgerError) {
        txnID = try await ledger.authorText(d, archiving: archiving)
        authored = d
        break
      } catch {
        lastError = error.detail
        if !Self.refusal(error) { break }
      }
    }
    guard let txnID else { return .failed(lastError) }
    if sender.kind == .bank, next != memory { await layouts.save(next) }
    return .added(
      BankTextAdded(
        txnID: txnID, bank: kept.bank, keptAtMs: arrival.receivedAtMs, filed: !authored.needsReview,
        unparsed: authored.payload["unparsed"]?.boolValue == true, repeatNumber: key.n, transferPartner: partner?.id))
  }

  static func refusal(_ e: MailboxLedgerError) -> Bool {
    e.detail.hasPrefix("invalid_op") || e.detail.hasPrefix("op_too_large") || e.detail.hasPrefix("refused")
  }
}
