import CoreDomain
import CoreExtract
import CoreReplay
import CoreTemplate
import CoreTime
import Foundation

public protocol BankTextLedger: Sendable {
  var textWrites: WriteSerial { get }
  func isIngested(_ ingestID: String) async -> Bool
  func textRows(postedFromMs: Int64, toMs: Int64) async -> [BankTextRow]?
  func mailRows(postedFromMs: Int64, toMs: Int64) async -> [TextTwinMail]?
  func authorText(_ draft: BankTextDraft, archiving: String?) async throws(MailboxLedgerError) -> String
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
  case pasteRefused
  case failed(String)
}

public actor BankTextAuthor {
  public static let maxRepeats = 1_000

  let ledger: any BankTextLedger
  let categorizer: any IngestCategorizer
  let templates: [CompiledTemplate]
  let banks: [String: String]
  private(set) var layouts = LearnedLayouts()

  public init(
    ledger: any BankTextLedger, categorizer: any IngestCategorizer = NoCategorizer(),
    templates: [CompiledTemplate] = BankTextReader.templates
  ) {
    self.ledger = ledger
    self.categorizer = categorizer
    self.templates = templates
    banks = BankTextSenders.bankSenders(templates: templates)
  }

  public nonisolated func add(
    _ arrival: BankTextArrival, secret: Data, link: @escaping @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    await run(arrival, origin: .automation, secret: secret, archiving: nil, link: link)
  }

  public nonisolated func paste(
    _ text: String, atMs: Int64, secret: Data, link: BankTextLink, replacing unparsedRowID: String? = nil
  ) async -> BankTextOutcome {
    if link == .linked { return .pasteRefused }
    return await run(
      BankTextArrival(text: text, sender: nil, receivedAtMs: atMs), origin: .paste, secret: secret, archiving: unparsedRowID,
      link: { link })
  }

  private nonisolated func run(
    _ arrival: BankTextArrival, origin: BankTextOrigin, secret: Data, archiving: String?,
    link: @escaping @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    guard secret.count == BankTextKey.secretBytes else { return .failed("secret") }
    do {
      return try await ledger.textWrites.run {
        await self.serialized(arrival, origin: origin, secret: secret, archiving: archiving, link: link)
      }
    } catch {
      return .failed("serial")
    }
  }

  private func serialized(
    _ arrival: BankTextArrival, origin: BankTextOrigin, secret: Data, archiving: String?,
    link: @Sendable () async -> BankTextLink
  ) async -> BankTextOutcome {
    let read = BankTextReader.read(arrival, templates: templates, banks: banks, layouts: layouts)
    if Task.isCancelled { return .failed("cancelled") }
    let kept: BankTextKept
    switch read.reading {
    case .setUpTest: return .testPassed
    case .dropped(let k, let counted, let bank): return .dropped(k, counted: counted, bank: bank)
    case .kept(let k): kept = k.timed(arrivalMinuteMs: arrival.arrivalMinuteMs)
    }
    let state = await link()
    if state == .linked { return .ignored(counted: kept.countsAsPayment, bank: kept.bank) }
    if Task.isCancelled { return .failed("cancelled") }

    let sender = read.sender
    let text = read.text
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
    var files = false
    if let f = kept.fields, let posted = try? parseInstantMs(f.postedAt) {
      let row = BankTextRow(
        id: "", bank: kept.bank, amountMinor: f.amountMinor, currency: f.currency, direction: f.direction, last4: f.last4,
        postedMs: posted, templateRef: kept.template?.ref, unparsed: false)
      var nearby: [BankTextRow]?
      var overlaps = false
      if row.transferRole != nil || (row.readerOnly && row.direction == "debit") {
        if let rows = await ledger.textRows(
          postedFromMs: posted - BankTextTransferPair.windowMs, toMs: posted + BankTextTransferPair.windowMs)
        {
          nearby = rows
          partner = BankTextTransferPair.partner(of: row, among: rows)
          overlaps = partner == nil && BankTextTransferPair.readerOverlap(of: row, among: rows)
        } else {
          overlaps = true
        }
      }
      files =
        !overlaps && BankTextPayload.filesItself(kept, link: state, origin: origin, transferPartner: partner != nil)
      if files { files = await !mayRepeat(row, n: key.n, nearby: nearby) }
    }
    let draft = BankTextPayload.build(kept, ingestID: key.id, receivedMinuteMs: minute, files: files, categorizer: categorizer)
    var txnID: String?
    var authored = draft
    var lastError = "author"
    for d in [draft] + BankTextPayload.fallbacks(draft, kept, receivedMinuteMs: minute) {
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
    if sender.learns { layouts = read.layouts }
    return .added(
      BankTextAdded(
        txnID: txnID, bank: kept.bank, keptAtMs: arrival.receivedAtMs, filed: !authored.needsReview,
        unparsed: authored.payload["unparsed"]?.boolValue == true, repeatNumber: key.n, transferPartner: partner?.id))
  }

  private func mayRepeat(_ row: BankTextRow, n: Int, nearby: [BankTextRow]?) async -> Bool {
    if n > 0 { return true }
    guard let mail = await ledger.mailRows(postedFromMs: row.postedMs - BankTextTwin.windowMs, toMs: row.postedMs + BankTextTwin.windowMs)
    else { return true }
    if mail.contains(where: { BankTextTwin.matches(row, $0) }) { return true }
    let bankless = (row.bank ?? "").isEmpty
    let w = DuplicateRules.probableCopyWindowMs
    let read: [BankTextRow]?
    if let nearby { read = nearby } else { read = await ledger.textRows(postedFromMs: row.postedMs - w, toMs: row.postedMs + w) }
    guard let texts = read else { return true }
    return texts.contains {
      (bankless || ($0.bank ?? "").isEmpty || BankTextPayload.readDifferently(row, $0)) && BankTextPayload.samePayment(row, $0)
    }
  }

  static func refusal(_ e: MailboxLedgerError) -> Bool {
    e.detail.hasPrefix("invalid_op") || e.detail.hasPrefix("op_too_large") || e.detail.hasPrefix("refused")
  }
}
