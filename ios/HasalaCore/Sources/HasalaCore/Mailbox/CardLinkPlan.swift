import CoreDomain
import CoreProjection
import CoreReplay
import CoreStore
import CoreTime
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

public struct CardAccounts: Sendable, Equatable {
  public var open: Set<String>
  public var closed: [String: OpAuthor.AccountDraft]

  public init(open: Set<String> = [], closed: [String: OpAuthor.AccountDraft] = [:]) {
    self.open = open
    self.closed = closed
  }

  public init(_ accounts: [Account]) {
    self.init()
    for a in accounts {
      if a.active {
        open.insert(a.id)
      } else if let d = CardLinkPlan.reopening(a) {
        closed[a.id] = d
      }
    }
  }
}

public enum CardLinkPlan {
  public static func plan(
    _ decisions: [CardDecision], accounts: CardAccounts, current: [CardKey: CardState], creditCards: Set<CardKey>
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
        if !accounts.open.contains(account), !created.contains(account) {
          if let reopen = accounts.closed[account] {
            create = reopen
          } else {
            let kind: OpAuthor.AccountKind = creditCards.contains(d.card) ? .creditCard : .current
            create = OpAuthor.AccountDraft(name: accountName(bank: bank, last4: d.card.last4), institution: bank, kind: kind)
          }
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
    bank: String?, last4: String, accounts: CardAccounts, current: [CardKey: CardState], creditCards: Set<CardKey>
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

  public static func draft(_ a: Account) -> OpAuthor.AccountDraft? {
    guard let kind = OpAuthor.AccountKind(rawValue: a.kind) else { return nil }
    return OpAuthor.AccountDraft(
      name: a.name, institution: a.institution, kind: kind, inPlan: a.inPlan, currency: a.currency,
      statementDueDay: kind == .creditCard ? a.statementDueDay : nil, active: a.active,
      closedOn: a.active ? nil : a.closedOn.flatMap(CivilDate.init(wire:)), color: a.color)
  }

  public static func reopening(_ a: Account) -> OpAuthor.AccountDraft? {
    guard var d = draft(a) else { return nil }
    d.active = true
    d.closedOn = nil
    return d
  }

  public static func closing(_ d: OpAuthor.AccountDraft, on day: CivilDate) -> OpAuthor.AccountDraft {
    var c = d
    c.active = false
    c.closedOn = day
    return c
  }

  public static func accountName(bank: String?, last4: String) -> String {
    "\(bank.map(RuntimeMailboxLedger.bankName) ?? "Card") ···\(last4)"
  }

  public static let cardFamilies = ["card.", "sms.purchase.", "sms.card-payment."]

  public static func isCardTemplate(_ ref: String, bank: String) -> Bool {
    !bank.isEmpty && cardFamilies.contains { ref.hasPrefix("\(bank).\($0)") }
  }

  public static func creditCards(_ cards: some Sequence<CardKey>, store: LedgerStore, reader: LedgerReader) -> Set<CardKey> {
    Set(cards.filter { isCreditCard($0, store: store, reader: reader) })
  }

  public static func isCreditCard(_ card: CardKey, store: LedgerStore, reader: LedgerReader) -> Bool {
    let gates = (try? MailboxTableStore(writer: store.db).stagedGates(bank: card.bank, last4: card.last4)) ?? []
    let dec = JSONDecoder()
    for json in gates {
      guard let g = try? dec.decode(MailGates.self, from: json), let t = g.template else { continue }
      if isCardTemplate(t, bank: card.bank) { return true }
    }
    guard !card.bank.isEmpty, !card.last4.isEmpty else { return false }
    let texts = (try? reader.textRows(bank: card.bank, last4: card.last4)) ?? []
    return texts.contains { t in t.templateRef.map { isCardTemplate($0, bank: card.bank) } ?? false }
  }
}
