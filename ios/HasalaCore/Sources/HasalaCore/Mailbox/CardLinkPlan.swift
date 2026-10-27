import CoreDomain
import CoreProjection
import CoreReplay
import CoreStore
import Foundation

public struct CardLinkStep: Sendable, Equatable {
  public enum Link: Sendable, Equatable {
    case mine(account: String, create: OpAuthor.AccountDraft?)
    case notMine
  }

  public var bank: String?
  public var last4: String
  public var link: Link
}

public enum CardLinkPlan {
  public static func plan(
    _ decisions: [CardDecision], accounts: Set<String>, current: [CardKey: CardState], creditCards: Set<CardKey>
  ) -> [CardLinkStep] {
    var created: Set<String> = []
    var steps: [CardLinkStep] = []
    for d in decisions {
      let bank: String? = d.card.bank.isEmpty ? nil : d.card.bank
      switch d.state {
      case .mine:
        if current[d.card] == .mine, d.accountID == nil { continue }
        let account = d.accountID ?? OpAuthor.cardAccountID(bank: bank, last4: d.card.last4)
        var create: OpAuthor.AccountDraft?
        if !accounts.contains(account), !created.contains(account) {
          let kind: OpAuthor.AccountKind = creditCards.contains(d.card) ? .creditCard : .current
          create = OpAuthor.AccountDraft(name: accountName(bank: bank, last4: d.card.last4), institution: bank, kind: kind)
          created.insert(account)
        }
        steps.append(CardLinkStep(bank: bank, last4: d.card.last4, link: .mine(account: account, create: create)))
      case .notMine:
        if current[d.card] == .notMine { continue }
        steps.append(CardLinkStep(bank: bank, last4: d.card.last4, link: .notMine))
      }
    }
    return steps
  }

  public static func confirming(
    bank: String?, last4: String, accounts: Set<String>, current: [CardKey: CardState], creditCards: Set<CardKey>
  ) -> [CardLinkStep] {
    guard let bank, !bank.isEmpty, !last4.isEmpty else { return [] }
    let card = CardKey(bank: bank, last4: last4)
    guard current[card] == nil else { return [] }
    return plan([CardDecision(card: card, state: .mine)], accounts: accounts, current: current, creditCards: creditCards)
  }

  public static func apply(_ steps: [CardLinkStep], to a: inout OpAuthor) throws(AuthorError) {
    for s in steps {
      switch s.link {
      case .mine(let account, let create):
        if let create { try a.setAccount(id: account, create) }
        a.linkCard(bank: s.bank, last4: s.last4, .mine(account: account))
      case .notMine:
        a.linkCard(bank: s.bank, last4: s.last4, .notMine)
      }
    }
  }

  public static func current(_ links: [CardLink]) -> [CardKey: CardState] {
    var out: [CardKey: CardState] = [:]
    for c in links {
      guard let s = CardState(rawValue: c.state) else { continue }
      out[CardKey(bank: c.bank ?? "", last4: c.last4)] = s
    }
    return out
  }

  public static func accountName(bank: String?, last4: String) -> String {
    "\(bank.map(RuntimeMailboxLedger.bankName) ?? "Card") ···\(last4)"
  }

  public static let cardFamilies = ["card.", "sms.purchase.", "sms.card-payment."]

  public static func isCardTemplate(_ ref: String, bank: String) -> Bool {
    !bank.isEmpty && cardFamilies.contains { ref.hasPrefix("\(bank).\($0)") }
  }

  public static func creditCards(_ store: LedgerStore, reader: LedgerReader) -> Set<CardKey> {
    let rows = (try? MailboxTableStore(writer: store.db).staged(limit: 10_000)) ?? []
    var out: Set<CardKey> = []
    for r in rows {
      guard let g = try? JSONDecoder().decode(MailGates.self, from: r.gatesJSON), let t = g.template,
        isCardTemplate(t, bank: r.bank)
      else { continue }
      out.insert(CardKey(bank: r.bank, last4: r.last4))
    }
    for t in (try? reader.textRows(postedFromMs: .min, toMs: .max)) ?? [] {
      guard let bank = t.bank, !t.last4.isEmpty, let ref = t.templateRef, isCardTemplate(ref, bank: bank) else { continue }
      out.insert(CardKey(bank: bank, last4: t.last4))
    }
    return out
  }
}
