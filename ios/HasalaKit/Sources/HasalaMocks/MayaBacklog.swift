import HasalaModels

public enum MayaBacklog {
  public struct Spelling: Sendable, Hashable {
    public var raw: String
    public var merchantKey: String
    public var group: String
    public var name: String
  }

  public static let tailscaleCom = Spelling(
    raw: "TAILSCALE.COM", merchantKey: "tailscale.com", group: "n:tailscale", name: "Tailscale")
  public static let tailscaleInc = Spelling(
    raw: "TAILSCALE INC", merchantKey: "tailscale inc", group: "n:tailscale", name: "Tailscale")
  public static let tailscalePaypal = Spelling(
    raw: "PAYPAL *TAILSCALE", merchantKey: "paypal *tailscale", group: "n:tailscale", name: "Tailscale")
  public static let qasrNumbered = Spelling(
    raw: "QASR CORNER STORE 0231", merchantKey: "qasr corner store 0231", group: "n:qasr corner store",
    name: "Qasr Corner Store")
  public static let qasr = Spelling(
    raw: "QASR CORNER STORE", merchantKey: "qasr corner store", group: "n:qasr corner store", name: "Qasr Corner Store")
  public static let brightwell = Spelling(
    raw: "BRIGHTWELL ACADEMY FZE", merchantKey: "brightwell academy fze", group: "n:brightwell academy",
    name: "Brightwell Academy")
  public static let saffron = Spelling(
    raw: "SAFFRON LANE TAILOR", merchantKey: "saffron lane tailor", group: "n:saffron lane tailor",
    name: "Saffron Lane Tailor")
  public static let nimbusCom = Spelling(
    raw: "NIMBUSNOTES.COM", merchantKey: "nimbusnotes.com", group: "n:nimbusnotes", name: "Nimbus Notes")
  public static let nimbusPaypal = Spelling(
    raw: "PAYPAL *NIMBUSNOTES", merchantKey: "paypal *nimbusnotes", group: "n:nimbusnotes", name: "Nimbus Notes")
  public static let alNoorTrading = Spelling(
    raw: "AL NOOR TRADING LLC", merchantKey: "al noor trading llc", group: "n:al noor trading", name: "Al Noor Trading")
  public static let alNoorPharmacy = Spelling(
    raw: "AL NOOR PHARMACY", merchantKey: "al noor pharmacy", group: "n:al noor pharmacy", name: "Al Noor Pharmacy")

  public static let mirdif = Spelling(
    raw: "MIRDIF BOOKS", merchantKey: "mirdif books", group: "n:mirdif books", name: "Mirdif Books")
  public static let mirdifLLC = Spelling(
    raw: "MIRDIF BOOKS LLC", merchantKey: "mirdif books llc", group: "n:mirdif books", name: "Mirdif Books")
  public static let mirdifNumbered = Spelling(
    raw: "MIRDIF BOOKS 0412", merchantKey: "mirdif books 0412", group: "n:mirdif books", name: "Mirdif Books")

  public static let spellings: [Spelling] = [
    tailscaleCom, tailscaleInc, tailscalePaypal, qasrNumbered, qasr, brightwell, saffron, nimbusCom, nimbusPaypal,
    alNoorTrading, alNoorPharmacy, mirdif, mirdifLLC, mirdifNumbered,
  ]

  public static let usdRateMicro: Int64 = 3_672_500
  public static let eurRateMicro: Int64 = 4_012_300

  public static let tailscale = MerchantGroupRef(key: tailscaleCom.group, direction: .out)
  public static let tailscaleRefunds = MerchantGroupRef(key: tailscaleCom.group, direction: .in)
  public static let qasrGroup = MerchantGroupRef(key: qasr.group, direction: .out)
  public static let brightwellGroup = MerchantGroupRef(key: brightwell.group, direction: .out)
  public static let saffronGroup = MerchantGroupRef(key: saffron.group, direction: .out)
  public static let nimbusGroup = MerchantGroupRef(key: nimbusCom.group, direction: .out)
  public static let alNoorTradingGroup = MerchantGroupRef(key: alNoorTrading.group, direction: .out)
  public static let alNoorPharmacyGroup = MerchantGroupRef(key: alNoorPharmacy.group, direction: .out)
  public static let mirdifGroup = MerchantGroupRef(key: mirdif.group, direction: .out)

  public static let wrongGuess: CategoryID = "shopping"

  public static let candidate = BillCandidate(
    id: "bl-cand-tailscale", name: "Tailscale", categoryID: "subscriptions", amount: Money(minor: 6_00, currency: "USD"),
    seenCount: 30, everyDays: 30, last: LocalDate(2026, 10, 9), key: tailscaleCom.merchantKey)

  public static func apply(to s: inout LedgerState) {
    s.txns += txns
    s.billCandidates.append(candidate)
    if !s.rates.contains(where: { $0.currency == "EUR" }) {
      s.rates.append(CurrencyRate(currency: "EUR", rateMicro: eurRateMicro))
    }
    MockReach.refresh(&s)
  }

  public static var txns: [Txn] { tailscaleRows + qasrRows + brightwellRows + otherRows + mirdifRows }

  static func row(
    _ id: String, _ spelling: Spelling, _ amount: Money, _ at: LocalDateTime, account: AccountID = "dib",
    direction: Direction = .out, category: CategoryID? = nil, source: CategorySource? = nil, needsReview: Bool = true,
    reason: TxnReviewReason? = nil, isNew: Bool = false
  ) -> Txn {
    let rate: Int64? =
      switch amount.currency {
      case "USD": usdRateMicro
      case "EUR": eurRateMicro
      default: nil
      }
    let home = rate.flatMap { ExchangeRates.convert(amount.minor, $0) } ?? Money.homeMinor(of: amount)
    let bank = account == "enbd" ? MayaLedger.enbd : MayaLedger.dib
    return Txn(
      id: id, merchant: spelling.name, amount: amount, homeMinor: .some(home),
      homeSource: .some(home == nil ? nil : rate == nil ? .identity : .rate), homeRateMicro: rate,
      direction: direction, postedAt: at, accountID: account, categoryID: category, categorySource: source,
      needsReview: needsReview, isNewMerchant: isNew,
      provenance: MayaLedger.alert(bank, at.time, spelling.raw), reviewReason: reason, merchantKey: spelling.merchantKey,
      merchantGroup: spelling.group)
  }

  static func usd(_ minor: Int64) -> Money { Money(minor: minor, currency: "USD") }
  static func eur(_ minor: Int64) -> Money { Money(minor: minor, currency: "EUR") }

  static let tailscaleDays: [(month: Int, day: Int)] =
    [1, 2, 3, 4, 6, 7, 8, 9].map { (10, $0) } + [1, 3, 6, 9, 12, 15, 18, 21].map { (9, $0) }
    + [2, 5, 8, 11, 14, 17, 20].map { (8, $0) } + [3, 6, 9, 12, 15, 18, 21].map { (7, $0) }

  static var tailscaleRows: [Txn] {
    let spellings = [tailscaleCom, tailscaleInc, tailscalePaypal]
    let amounts: [Int64] = [6_00, 18_00, 12_00]
    var rows = tailscaleDays.enumerated().map { i, d in
      row(
        "bl-ts-\(i + 1 < 10 ? "0" : "")\(i + 1)", spellings[i % 3], usd(amounts[i % 3]),
        LocalDateTime(2026, d.month, d.day, 3, 10 + i))
    }
    rows.append(row("bl-ts-unverified", tailscaleCom, usd(6_00), LocalDateTime(2026, 10, 5, 3, 12),
                    reason: .senderUnverified))
    rows.append(row("bl-ts-refund", tailscaleCom, usd(6_00), LocalDateTime(2026, 10, 7, 20, 5), direction: .in))
    return rows
  }

  static var qasrRows: [Txn] {
    let filed: [(Int, Int, Int64, CategoryID)] = [
      (8, 4, 31_25, "groceries"), (8, 12, 64_00, "shopping"), (8, 19, 22_80, "groceries"),
      (8, 26, 47_10, "groceries"), (9, 2, 89_00, "shopping"), (9, 9, 28_45, "groceries"), (9, 16, 55_00, "shopping"),
    ]
    let waiting: [(Int, Int, Int64)] = [
      (8, 30, 23_50), (9, 20, 41_75), (9, 27, 18_20), (10, 2, 36_00), (10, 5, 52_40), (10, 8, 27_90),
    ]
    let history = filed.enumerated().map { i, f in
      row("bl-qasr-filed-\(i + 1)", i % 2 == 0 ? qasrNumbered : qasr, .aed(f.2), LocalDateTime(2026, f.0, f.1, 19, 20),
          account: "enbd", category: f.3, source: .user, needsReview: false)
    }
    let open = waiting.enumerated().map { i, w in
      row("bl-qasr-\(i + 1)", i % 2 == 0 ? qasrNumbered : qasr, .aed(w.2), LocalDateTime(2026, w.0, w.1, 19, 40),
          account: "enbd")
    }
    return history + open
  }

  static var brightwellRows: [Txn] {
    [7, 8, 9, 10].map { m in
      row("bl-bright-\(m)", brightwell, .aed(450_00), LocalDateTime(2026, m, 3, 9, 0), category: wrongGuess,
          source: .model(tag: "cf-clef/1"))
    }
  }

  static var mirdifRows: [Txn] {
    let guess = CategorySource.model(tag: "cf-clef/1")
    return [
      row("bl-mirdif-1", mirdifNumbered, usd(80_00), LocalDateTime(2026, 10, 2, 16, 20), category: wrongGuess, source: guess),
      row("bl-mirdif-2", mirdif, usd(40_00), LocalDateTime(2026, 10, 4, 16, 20), category: wrongGuess, source: guess),
      row("bl-mirdif-3", mirdifLLC, .aed(312_50), LocalDateTime(2026, 10, 8, 16, 20), category: wrongGuess, source: guess),
      row("bl-mirdif-4", mirdif, .aed(349_21), LocalDateTime(2026, 10, 9, 16, 20), category: wrongGuess, source: guess),
      row("bl-mirdif-unverified", mirdifLLC, .aed(95_00), LocalDateTime(2026, 10, 6, 16, 20), reason: .senderUnverified),
    ]
  }

  static var otherRows: [Txn] {
    [
      row("bl-saffron", saffron, .aed(85_00), LocalDateTime(2026, 10, 6, 17, 45), isNew: true),
      row("bl-nimbus-7", nimbusCom, usd(8_00), LocalDateTime(2026, 7, 14, 6, 0)),
      row("bl-nimbus-8", nimbusCom, usd(8_00), LocalDateTime(2026, 8, 14, 6, 0)),
      row("bl-nimbus-9", nimbusCom, usd(8_00), LocalDateTime(2026, 9, 14, 6, 0)),
      row("bl-nimbus-9b", nimbusPaypal, eur(7_50), LocalDateTime(2026, 9, 28, 6, 0)),
      row("bl-nimbus-10", nimbusPaypal, eur(7_50), LocalDateTime(2026, 10, 8, 6, 0)),
      row("bl-alnoor-t-1", alNoorTrading, .aed(120_00), LocalDateTime(2026, 9, 22, 12, 30), account: "enbd"),
      row("bl-alnoor-t-2", alNoorTrading, .aed(64_50), LocalDateTime(2026, 10, 1, 12, 30), account: "enbd"),
      row("bl-alnoor-t-3", alNoorTrading, .aed(210_00), LocalDateTime(2026, 10, 9, 12, 30), account: "enbd"),
      row("bl-alnoor-p-1", alNoorPharmacy, .aed(38_75), LocalDateTime(2026, 9, 24, 18, 15)),
      row("bl-alnoor-p-2", alNoorPharmacy, .aed(55_00), LocalDateTime(2026, 10, 4, 18, 15)),
    ]
  }
}
