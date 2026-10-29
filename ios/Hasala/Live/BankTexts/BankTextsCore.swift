import Foundation
import HasalaModels

nonisolated enum BankTextDropKind: String, Codable, CaseIterable, Sendable {
  case oneTimeCode
  case declined
  case notice
  case promotion
  case noPaymentShape
}

nonisolated struct BankTextFields: Equatable, Sendable {
  var bank: String?
  var amount: Money?
  var direction: Direction?
  var merchant: String?
  var postedAt: Date?
  var cardEnding: String?

  init(
    bank: String? = nil, amount: Money? = nil, direction: Direction? = nil, merchant: String? = nil,
    postedAt: Date? = nil, cardEnding: String? = nil
  ) {
    self.bank = bank
    self.amount = amount
    self.direction = direction
    self.merchant = merchant
    self.postedAt = postedAt
    self.cardEnding = cardEnding
  }

  var unparsed: Bool { amount == nil }
}

nonisolated struct KeptBankText: Equatable, Sendable {
  var fields: BankTextFields
  var mayBeBanks: Bool

  init(fields: BankTextFields, mayBeBanks: Bool) {
    self.fields = fields
    self.mayBeBanks = mayBeBanks
  }
}

nonisolated enum BankTextRead: Equatable, Sendable {
  case setUpTest
  case drop(BankTextDropKind, setAsideSender: String?, bank: String?)
  case keep(KeptBankText)
}

nonisolated enum BankTextLinkState: Equatable, Sendable {
  case notLinked
  case linked
  case unknownUnanswered
}

nonisolated enum BankTextRoute: Equatable, Sendable {
  case automation
  case paste(replacing: String?)
}

nonisolated enum BankTextAuthored: Equatable, Sendable {
  case authored(rowID: String, filed: Bool, keptAt: Date)
  case ignoredLinked(counts: Bool)
}

nonisolated enum BankTextsCoreFailure: Error, Equatable, Sendable {
  case unavailable
  case notAPayment
  case failed
}

nonisolated struct PasteRow: Equatable, Sendable {
  var id: String
  var fromText: Bool
  var unparsed: Bool
  var bank: String?
  var cardEnding: String?
  var amount: Money?
  var direction: Direction?
  var merchant: String?
  var postedAt: Date

  init(
    id: String, fromText: Bool, unparsed: Bool = false, bank: String? = nil, cardEnding: String? = nil,
    amount: Money? = nil, direction: Direction? = nil, merchant: String? = nil, postedAt: Date
  ) {
    self.id = id
    self.fromText = fromText
    self.unparsed = unparsed
    self.bank = bank
    self.cardEnding = cardEnding
    self.amount = amount
    self.direction = direction
    self.merchant = merchant
    self.postedAt = postedAt
  }
}

nonisolated protocol BankTextsReading: Sendable {
  func read(_ text: String, sender: String?, testWindowOpen: Bool) -> BankTextRead
  func readPaste(_ text: String, pastedAt: Date) -> BankTextRead
}

nonisolated extension BankTextsReading {
  func readPaste(_ text: String, pastedAt: Date) -> BankTextRead {
    read(text, sender: nil, testWindowOpen: false)
  }
}

nonisolated protocol BankTextsAuthoring: Sendable {
  func author(
    _ text: String, sender: String?, reading: KeptBankText, arrivedAt: Date, secret: Data, link: BankTextLinkState,
    origin: BankTextRoute
  ) async throws(BankTextsCoreFailure) -> BankTextAuthored
  func liveRows(postedFrom: Date, through: Date) async -> [PasteRow]
}

nonisolated struct UnwiredBankTextsCore: BankTextsReading, BankTextsAuthoring {
  func read(_ text: String, sender: String?, testWindowOpen: Bool) -> BankTextRead {
    if testWindowOpen, BankTextsTestPhrase.matches(text) { return .setUpTest }
    return .keep(KeptBankText(fields: BankTextFields(), mayBeBanks: true))
  }

  func author(
    _ text: String, sender: String?, reading: KeptBankText, arrivedAt: Date, secret: Data, link: BankTextLinkState,
    origin: BankTextRoute
  ) async throws(BankTextsCoreFailure) -> BankTextAuthored {
    throw .unavailable
  }

  func liveRows(postedFrom: Date, through: Date) async -> [PasteRow] { [] }
}

nonisolated enum BankTextsTestPhrase {
  static func matches(_ text: String) -> Bool {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    return words == ["hasala", "test"]
  }
}

extension SupportedBank {
  init?(coreBank: String?) {
    guard let coreBank else { return nil }
    self.init(rawValue: coreBank.lowercased())
  }
}
