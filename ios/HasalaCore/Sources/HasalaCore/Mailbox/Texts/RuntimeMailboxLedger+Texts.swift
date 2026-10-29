import CoreDomain
import CoreProjection
import Foundation

extension RuntimeMailboxLedger: BankTextLedger {
  public func textRows(postedFromMs: Int64, toMs: Int64) async -> [BankTextRow] {
    ((try? reader.textRows(postedFromMs: postedFromMs, toMs: toMs)) ?? []).map(BankTextRow.init)
  }

  public func mailRows(postedFromMs: Int64, toMs: Int64) async -> [TextTwinMail] {
    ((try? reader.liveRows(postedFromMs: postedFromMs, toMs: toMs)) ?? []).compactMap { t in
      guard !t.isText, !t.unparsed, t.entryMethod == "mailbox" else { return nil }
      return TextTwinMail(
        bank: t.bank, last4: t.last4, amountMinor: t.amountMinor, currency: t.currency, direction: t.direction, postedMs: t.postedMs)
    }
  }

  public func textOverlap() async throws(MailboxLedgerError) -> TextOverlap? {
    do {
      guard let span = try reader.textRowSpan() else { return nil }
      let rows = try reader.textRows(postedFromMs: span.oldestPostedMs, toMs: span.newestPostedMs).map(BankTextRow.init)
      return TextOverlap(span: span, rows: rows)
    } catch {
      throw MailboxLedgerError("texts")
    }
  }

  public func authorText(_ draft: BankTextDraft, archiving: String?) async throws(MailboxLedgerError) -> String {
    var id: String?
    try await author { a throws(AuthorError) in
      id = try a.ingest(payload: draft.payload, ingestID: draft.ingestID)
      if let archiving { a.annotate(txnID: archiving, set: [("archived", "user")]) }
    }
    guard let id else { throw MailboxLedgerError("not_authored") }
    return id
  }
}

extension BankTextRow {
  public init(_ t: TxnRow) {
    self.init(
      id: t.id, bank: t.bank, amountMinor: t.amountMinor, currency: t.currency, direction: t.direction, last4: t.last4,
      postedMs: t.postedMs, templateRef: t.templateRef, unparsed: t.unparsed)
  }
}
