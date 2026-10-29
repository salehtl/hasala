import CoreMailbox
import CoreProjection
import CoreTime
import Foundation
import HasalaModels

nonisolated enum CoreBankTextMapping {
  static let datedProbeMs: Int64 = 3 * 86_400_000 + 7 * 60_000

  static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }

  static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

  static func kind(_ raw: String) -> BankTextDropKind {
    switch raw {
    case "one_time_code": .oneTimeCode
    case "declined": .declined
    case "notice": .notice
    case "promotion": .promotion
    default: .noPaymentShape
    }
  }

  static func direction(_ raw: String) -> Direction { raw == "credit" ? .in : .out }

  static func read(_ reading: CoreMailbox.BankTextReading, sender: String?, arrivalMinuteMs: Int64, dated: Bool)
    -> BankTextRead
  {
    switch reading {
    case .setUpTest: return .setUpTest
    case .dropped(let k, let counted, let bank):
      return .drop(kind(k.rawValue), setAsideSender: counted ? sender : nil, bank: counted ? bank : nil)
    case .kept(let kept):
      return .keep(
        KeptBankText(
          fields: fields(kept.timed(arrivalMinuteMs: arrivalMinuteMs), dated: dated), mayBeBanks: kept.countsAsPayment))
    }
  }

  static func fields(_ k: BankTextKept, dated: Bool) -> BankTextFields {
    let f = k.fields
    let posted = dated ? (try? parseInstantMs(f?.postedAt ?? k.postedAt)).map(date) : nil
    let merchant = f?.merchant ?? k.merchant
    let last4 = f?.last4 ?? k.last4
    return BankTextFields(
      bank: k.bank, amount: f.map { Money(minor: $0.amountMinor, currency: $0.currency) },
      direction: f.map { direction($0.direction) }, merchant: merchant.isEmpty ? nil : merchant, postedAt: posted,
      cardEnding: last4.isEmpty ? nil : last4)
  }

  static func row(_ t: TxnRow) -> PasteRow {
    let name = t.displayName.isEmpty ? t.merchantRaw : t.displayName
    return PasteRow(
      id: t.id, fromText: t.isText, unparsed: t.unparsed, bank: t.bank, cardEnding: t.last4.isEmpty ? nil : t.last4,
      amount: t.unparsed ? nil : Money(minor: t.amountMinor, currency: t.currency),
      direction: t.unparsed ? nil : direction(t.direction), merchant: name.isEmpty ? nil : name, postedAt: date(t.postedMs))
  }

  static func link(_ state: BankTextLinkState) -> BankTextLink {
    switch state {
    case .notLinked: .notLinked
    case .linked: .linked
    case .unknownUnanswered: .unknownUnanswered
    }
  }

  static func authored(_ outcome: BankTextOutcome) throws(BankTextsCoreFailure) -> BankTextAuthored {
    switch outcome {
    case .added(let a): return .authored(rowID: a.txnID, filed: a.filed, keptAt: date(a.keptAtMs))
    case .ignored(let counted, _): return .ignoredLinked(counts: counted)
    case .testPassed, .dropped: throw .notAPayment
    case .pasteRefused, .failed: throw .failed
    }
  }
}

nonisolated struct CoreBankTextReader: BankTextsReading {
  var now: @Sendable () -> Date = { .now }

  func read(_ text: String, sender: String?, testWindowOpen: Bool) -> BankTextRead {
    let arrival = BankTextArrival(
      text: text, sender: sender, receivedAtMs: CoreBankTextMapping.ms(now()), testWindowOpen: testWindowOpen)
    return CoreBankTextMapping.read(
      BankTextReader.read(arrival).reading, sender: sender, arrivalMinuteMs: arrival.arrivalMinuteMs, dated: true)
  }

  func readPaste(_ text: String, pastedAt: Date) -> BankTextRead {
    let arrival = BankTextArrival(text: text, sender: nil, receivedAtMs: CoreBankTextMapping.ms(pastedAt))
    let first = BankTextReader.read(arrival).reading
    let probe = BankTextArrival(
      text: text, sender: nil, receivedAtMs: arrival.receivedAtMs + CoreBankTextMapping.datedProbeMs)
    let dated = Self.dated(first.kept, later: BankTextReader.read(probe).reading.kept)
    return CoreBankTextMapping.read(first, sender: nil, arrivalMinuteMs: arrival.arrivalMinuteMs, dated: dated)
  }

  static func dated(_ first: BankTextKept?, later: BankTextKept?) -> Bool {
    guard let first, let later,
      let a = try? parseInstantMs(first.fields?.postedAt ?? first.postedAt),
      let b = try? parseInstantMs(later.fields?.postedAt ?? later.postedAt)
    else { return false }
    return b - a != CoreBankTextMapping.datedProbeMs
  }
}

nonisolated struct CoreBankTextAuthoring: BankTextsAuthoring {
  let core: BankTextAuthor
  let rows: @Sendable (_ fromMs: Int64, _ toMs: Int64) async -> [TxnRow]

  init(core: BankTextAuthor, rows: @escaping @Sendable (_ fromMs: Int64, _ toMs: Int64) async -> [TxnRow]) {
    self.core = core
    self.rows = rows
  }

  init(ledger: RuntimeMailboxLedger, reader: LedgerReader, categorizer: any IngestCategorizer) {
    self.init(
      core: BankTextAuthor(ledger: ledger, categorizer: categorizer),
      rows: { from, to in (try? reader.liveRows(postedFromMs: from, toMs: to)) ?? [] })
  }

  func author(
    _ text: String, sender: String?, reading: KeptBankText, arrivedAt: Date, secret: Data, link: BankTextLinkState,
    origin: BankTextRoute
  ) async throws(BankTextsCoreFailure) -> BankTextAuthored {
    let state = CoreBankTextMapping.link(link)
    let atMs = CoreBankTextMapping.ms(arrivedAt)
    let outcome: BankTextOutcome
    switch origin {
    case .automation:
      outcome = await core.add(
        BankTextArrival(text: text, sender: sender, receivedAtMs: atMs), secret: secret, link: { state })
    case .paste(let replacing):
      outcome = await core.paste(text, atMs: atMs, secret: secret, link: state, replacing: replacing)
    }
    return try CoreBankTextMapping.authored(outcome)
  }

  func liveRows(postedFrom: Date, through: Date) async -> [PasteRow] {
    await rows(CoreBankTextMapping.ms(postedFrom), CoreBankTextMapping.ms(through)).map(CoreBankTextMapping.row)
  }
}
