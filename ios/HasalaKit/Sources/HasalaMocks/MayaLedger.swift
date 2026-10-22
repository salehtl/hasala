import HasalaModels

// MayaLedger (spec 04 §15.3): the Maya scenario as a whole ledger, so every screen
// (Home, Activity, the transaction sheet, Review, Plan, Bills, Profile) reads the
// same data and agrees with the Paper boards' figures:
//
// - Everyday: 2,282.45 spent of 9,700.00 (Groceries 812.40, Dining 642.75, Shopping
//   431.80, Transport 214.50, Entertainment 95.00, Healthcare 86.00).
// - Bills paid 8,005.89 (rent 7,500.00, du 427.90, Netflix 56.00, Spotify 21.99);
//   bills to come 1,039.15 (DEWA ~489.15, AXA 550.00 three days late).
// - Six to review, 827.28 of spending not in the plan; 26 transactions this month.
// - Income 25,000 planned 24,000: Ready to assign 1,000.00.
//
// Every name, amount, card suffix and reference here is synthetic (CLAUDE.md).

public enum MayaLedger {
  /// Saturday 10 October 2026, 13:40 in the ledger clock.
  public static let now = LocalDateTime(2026, 10, 10, 13, 40)
  public static let october = YearMonth(2026, 10)

  public static var state: LedgerState {
    LedgerState(
      categories: categories, accounts: accounts, txns: txns, plan: plan, bills: bills,
      billCandidates: candidates, projects: projects, goals: goals, rules: rules,
      profile: ProfileInfo(displayName: Maya.displayName, email: "maya@example.com", signIn: .passkey),
      mailbox: MailboxHealth(status: .working, lastEmail: "4 min ago", banks: "Emirates NBD and DIB"),
      prefs: DevicePrefs(),
      netWorth: NetWorthHistory(monthChange: .aed(2_140_00),
                                spark: [171, 229, 200, 329, 300, 429, 400, 557, 529, 686, 743])
    )
  }

  // MARK: - Categories (03c §4.1 taxonomy v1, plus the goal's own category)

  static let categories: [Category] = [
    Category(id: "rent", name: "Rent", bucket: .needs, glyph: .rent, role: .bill, builtin: true),
    Category(id: "utilities", name: "Utilities", bucket: .needs, glyph: .utilities, role: .bill, builtin: true),
    Category(id: "groceries", name: "Groceries", bucket: .needs, glyph: .groceries, builtin: true),
    Category(id: "transport", name: "Transport", bucket: .needs, glyph: .transport, builtin: true),
    Category(id: "healthcare", name: "Healthcare", bucket: .needs, glyph: .healthcare, builtin: true),
    Category(id: "insurance", name: "Insurance", bucket: .needs, glyph: .insurance, role: .bill, builtin: true),
    Category(id: "dining", name: "Dining", bucket: .wants, glyph: .dining, builtin: true),
    Category(id: "entertainment", name: "Entertainment", bucket: .wants, glyph: .entertainment, builtin: true),
    Category(id: "shopping", name: "Shopping", bucket: .wants, glyph: .shopping, builtin: true),
    Category(id: "travel", name: "Travel", bucket: .wants, glyph: .travel, builtin: true),
    Category(id: "subscriptions", name: "Subscriptions", bucket: .wants, glyph: .subscriptions, role: .bill, builtin: true),
    Category(id: "savings", name: "Savings", bucket: .savings, glyph: .savingsJar, role: .saving, builtin: true),
    Category(id: "investments", name: "Investments", bucket: .savings, glyph: .investments, role: .saving, builtin: true),
    // Maya retired Debt; 18 categories remain, as on her profile.
    Category(id: "debt", name: "Debt", bucket: .savings, glyph: .debt, role: .saving, archived: true, builtin: true),
    Category(id: "emergency-fund", name: "Emergency fund", bucket: .savings, glyph: .savingsJar, role: .saving, parent: "savings"),
    Category(id: "salary", name: "Salary", kind: .income, bucket: .income, glyph: .salary, role: .none, builtin: true),
    Category(id: "freelance", name: "Freelance", kind: .income, bucket: .income, glyph: .freelance, role: .none, builtin: true),
    Category(id: "transfer", name: "Transfer", kind: .excluded, bucket: .other, glyph: .transfer, role: .none, builtin: true),
    Category(id: "refunds", name: "Refunds", kind: .excluded, bucket: .other, glyph: .refunds, role: .none, builtin: true),
  ]

  // MARK: - Accounts (net worth 227,568.00)

  static let accounts: [Account] = [
    Account(id: "enbd", name: "Emirates NBD Current", shortName: "Emirates NBD", last4: "4412", kind: .current,
            balance: .aed(41_823_50), detail: "checked in 3 days ago · 6 since"),
    Account(id: "dib", name: "DIB Credit Card", shortName: "DIB card", last4: "8891", kind: .credit,
            balance: .aed(-4_210_50), detail: "statement due Sun 18 Oct"),
    Account(id: "cash", name: "Cash", shortName: "Cash", kind: .cash, balance: .aed(550_00), detail: "Updated by you"),
    Account(id: "sarwa", name: "Sarwa portfolio", shortName: "Sarwa", kind: .investment, balance: .aed(189_405_00),
            inPlan: false, detail: "Net worth only · updated 1 Oct"),
  ]

  // MARK: - Plan

  static let plan = PlanState(
    income: .aed(25_000_00), payday: 28, startingSplit: [50, 30, 20],
    budgets: Dictionary(uniqueKeysWithValues: [
      ("rent", 7_500_00), ("utilities", 900_00), ("groceries", 2_200_00), ("transport", 900_00),
      ("healthcare", 300_00), ("insurance", 550_00), ("dining", 1_600_00), ("entertainment", 600_00),
      ("shopping", 1_600_00), ("travel", 2_500_00), ("subscriptions", 350_00), ("savings", 3_000_00),
      ("investments", 2_000_00),
    ].flatMap { row in
      [YearMonth(2026, 8), YearMonth(2026, 9), october].map { (PlanState.key(row.0, $0), Money.aed(Int64(row.1))) }
    })
  )

  // MARK: - Transactions

  static func alert(_ bank: String, _ time: String, _ raw: String) -> Provenance {
    Provenance(title: "\(bank) transaction alert", readAt: "Read automatically at \(time)", rawMerchant: raw)
  }

  static func oct(_ d: Int, _ h: Int, _ m: Int) -> LocalDateTime { LocalDateTime(2026, 10, d, h, m) }

  static let enbd = "Emirates NBD"
  static let dib = "DIB"

  static let txns: [Txn] = [
    // Saturday 10 October (today).
    Txn(id: "talabat", merchant: "Talabat", amount: .aed(64_50), postedAt: oct(10, 13, 20), accountID: "dib",
        categoryID: "dining", categorySource: .rule(pattern: "talabat"),
        provenance: alert(dib, "13:20", "TALABAT DUBAI")),
    Txn(id: "starbucks", merchant: "Starbucks", place: "DIFC", amount: .aed(27_00), postedAt: oct(10, 9, 5),
        accountID: "dib", categoryID: "dining", categorySource: .dictionary,
        provenance: alert(dib, "09:05", "STARBUCKS DIFC GATE")),
    Txn(id: "steam", merchant: "Steam", amount: .aed(59_49), postedAt: oct(10, 11, 2), accountID: "dib",
        needsReview: true, isNewMerchant: true, suggestion: "entertainment",
        provenance: alert(dib, "11:02", "STEAMPOWERED.COM"), reviewReason: .senderUnverified),
    Txn(id: "dubai-taxi", merchant: "Dubai Taxi", amount: .aed(38_50), postedAt: oct(10, 8, 10), accountID: "dib",
        needsReview: true, isNewMerchant: true, suggestion: "transport",
        provenance: alert(dib, "08:10", "DUBAI TAXI CORP")),
    // Friday 9 October.
    Txn(id: "careem", merchant: "Careem", amount: .aed(46_00), postedAt: oct(9, 23, 40), accountID: "dib",
        categoryID: "transport", categorySource: .rule(pattern: "careem"),
        provenance: alert(dib, "23:40", "CAREEM HALA RIDE")),
    Txn(id: "carrefour", merchant: "Carrefour", amount: .aed(342_15), postedAt: oct(9, 19, 12), accountID: "enbd",
        categoryID: "groceries", categorySource: .rule(pattern: "carrefour"),
        provenance: alert(enbd, "19:12", "CARREFOUR MALL OF EMIRATES")),
    Txn(id: "lulu", merchant: "Lulu Hypermarket", amount: .aed(214_30), postedAt: oct(9, 18, 42), accountID: "dib",
        categorySource: .model(tag: "cf-clef/1"), needsReview: true, isNewMerchant: true, suggestion: "groceries",
        provenance: alert(dib, "18:42", "LULU HYPERMARKET DXB MARINA")),
    // Thursday 8 October.
    Txn(id: "vox", merchant: "VOX Cinemas", amount: .aed(95_00), postedAt: oct(8, 21, 10), accountID: "dib",
        categoryID: "entertainment", categorySource: .dictionary, provenance: alert(dib, "21:10", "VOX CINEMAS MOE")),
    Txn(id: "spotify", merchant: "Spotify", amount: .aed(21_99), postedAt: oct(8, 6, 0), accountID: "dib",
        categoryID: "subscriptions", categorySource: .dictionary, billID: "spotify",
        provenance: alert(dib, "06:00", "SPOTIFY P2F3A1"), detailOverride: "monthly bill"),
    Txn(id: "apple", merchant: "Apple.com", amount: .aed(14_99), postedAt: oct(8, 3, 0), accountID: "dib",
        needsReview: true, suggestion: "subscriptions", provenance: alert(dib, "03:00", "APPLE.COM/BILL")),
    // Wednesday 7 October.
    Txn(id: "zuma", merchant: "Zuma", amount: .aed(412_00), postedAt: oct(7, 21, 30), accountID: "dib",
        categoryID: "dining", categorySource: .rule(pattern: "zuma"), provenance: alert(dib, "21:30", "ZUMA DIFC")),
    Txn(id: "noon", merchant: "Noon", amount: .aed(189_00), postedAt: oct(7, 14, 25), accountID: "enbd",
        categoryID: "shopping", categorySource: .dictionary, provenance: alert(enbd, "14:25", "NOON.COM"),
        detailOverride: "Emirates NBD"),
    Txn(id: "transfer-in", merchant: "Transfer from ···7890", amount: .aed(1_250_00), direction: .in,
        postedAt: oct(7, 9, 30), accountID: "enbd", needsReview: true,
        provenance: alert(enbd, "09:30", "INWARD TRANSFER ···7890")),
    // Tuesday 6 October.
    Txn(id: "atm", merchant: "ADCB ATM withdrawal", amount: .aed(500_00), postedAt: oct(6, 20, 10), accountID: "enbd",
        needsReview: true, suggestion: "transfer", provenance: alert(enbd, "20:10", "ATM WDL ADCB MARINA")),
    Txn(id: "waitrose", merchant: "Waitrose", amount: .aed(254_85), postedAt: oct(6, 18, 5), accountID: "enbd",
        categoryID: "groceries", categorySource: .dictionary, provenance: alert(enbd, "18:05", "WAITROSE DUBAI MALL")),
    Txn(id: "common-grounds", merchant: "Common Grounds", amount: .aed(81_00), postedAt: oct(6, 10, 15),
        accountID: "dib", categoryID: "dining", categorySource: .user,
        provenance: alert(dib, "10:15", "COMMON GROUNDS MOE")),
    Txn(id: "netflix", merchant: "Netflix", amount: .aed(56_00), postedAt: oct(6, 7, 0), accountID: "dib",
        categoryID: "subscriptions", categorySource: .rule(pattern: "NETFLIX.COM"), billID: "netflix",
        provenance: alert(dib, "07:00", "NETFLIX.COM"), detailOverride: "monthly bill"),
    // Monday 5 October.
    Txn(id: "ikea", merchant: "IKEA", amount: .aed(242_80), postedAt: oct(5, 17, 40), accountID: "enbd",
        categoryID: "shopping", categorySource: .dictionary, provenance: alert(enbd, "17:40", "IKEA FESTIVAL CITY")),
    Txn(id: "du", merchant: "du", amount: .aed(427_90), postedAt: oct(5, 9, 0), accountID: "enbd",
        categoryID: "utilities", categorySource: .dictionary, billID: "du",
        provenance: alert(enbd, "09:00", "DU TELECOM"), detailOverride: "monthly bill"),
    // Sunday 4 October.
    Txn(id: "aster", merchant: "Aster Pharmacy", amount: .aed(86_00), postedAt: oct(4, 12, 30), accountID: "dib",
        categoryID: "healthcare", categorySource: .dictionary, provenance: alert(dib, "12:30", "ASTER PHARMACY 112")),
    Txn(id: "enoc", merchant: "ENOC", amount: .aed(168_50), postedAt: oct(4, 8, 15), accountID: "dib",
        categoryID: "transport", categorySource: .dictionary, provenance: alert(dib, "08:15", "ENOC 1043")),
    // Saturday 3 October.
    Txn(id: "talabat-3", merchant: "Talabat", amount: .aed(58_25), postedAt: oct(3, 20, 45), accountID: "dib",
        categoryID: "dining", categorySource: .rule(pattern: "talabat"),
        provenance: alert(dib, "20:45", "TALABAT DUBAI")),
    Txn(id: "spinneys", merchant: "Spinneys", amount: .aed(215_40), postedAt: oct(3, 11, 20), accountID: "enbd",
        categoryID: "groceries", categorySource: .dictionary, provenance: alert(enbd, "11:20", "SPINNEYS MARINA")),
    // Friday 2 October: savings.
    Txn(id: "standing-order", merchant: "Standing order", amount: .aed(3_000_00), postedAt: oct(2, 8, 0),
        accountID: "enbd", categoryID: "savings", categorySource: .user, billID: "savings-so",
        detailOverride: "to savings"),
    Txn(id: "sarwa", merchant: "Sarwa", amount: .aed(2_000_00), postedAt: oct(2, 8, 5), accountID: "enbd",
        categoryID: "investments", categorySource: .user, billID: "sarwa-so", detailOverride: "monthly"),
    // Thursday 1 October: rent.
    Txn(id: "rent", merchant: "Al Habtoor", amount: .aed(7_500_00), postedAt: oct(1, 9, 0), accountID: "enbd",
        categoryID: "rent", categorySource: .user, billID: "rent", detailOverride: "monthly bill"),

    // September: the Japan trip and earlier groceries (search and project history).
    Txn(id: "emirates", merchant: "Emirates", amount: .aed(4_120_00), postedAt: LocalDateTime(2026, 9, 14, 10, 0),
        accountID: "dib", categoryID: "travel", categorySource: .user, note: "Emirates flights", projectID: "japan"),
    Txn(id: "jr-pass", merchant: "JR Pass via Klook", amount: .aed(740_00), postedAt: LocalDateTime(2026, 9, 19, 16, 0),
        accountID: "dib", categoryID: "transport", categorySource: .user, note: "JR Pass", projectID: "japan"),
    Txn(id: "carrefour-sep26", merchant: "Carrefour", amount: .aed(288_60), postedAt: LocalDateTime(2026, 9, 26, 18, 0),
        accountID: "enbd", categoryID: "groceries", categorySource: .rule(pattern: "carrefour")),
    Txn(id: "carrefour-sep13", merchant: "Carrefour", amount: .aed(401_20), postedAt: LocalDateTime(2026, 9, 13, 12, 0),
        accountID: "enbd", categoryID: "groceries", categorySource: .rule(pattern: "carrefour")),
  ]

  // MARK: - Bills (9 tracked)

  static let bills: [Bill] = [
    Bill(id: "axa", name: "AXA Insurance", kind: "Car insurance", categoryID: "insurance", amount: .aed(550_00),
         usualDay: 7, nextDue: LocalDate(2026, 10, 7), accountID: "enbd",
         history: [LocalDate(2026, 9, 7), LocalDate(2026, 8, 7), LocalDate(2026, 7, 6), LocalDate(2026, 6, 8),
                   LocalDate(2026, 5, 7), LocalDate(2026, 4, 7)]),
    Bill(id: "dewa", name: "DEWA", kind: "Electricity & water", categoryID: "utilities", amount: .aed(489_15),
         approximate: true, usualDay: 14, nextDue: LocalDate(2026, 10, 14), accountID: "enbd"),
    Bill(id: "du", name: "du", kind: "Mobile and internet", categoryID: "utilities", amount: .aed(427_90),
         usualDay: 5, nextDue: LocalDate(2026, 11, 5), accountID: "enbd", priceChangeFrom: .aed(389_00),
         history: [LocalDate(2026, 10, 5), LocalDate(2026, 9, 5)]),
    Bill(id: "salary", name: "Salary · Acme Gulf", kind: "Salary", categoryID: "salary", amount: .aed(25_000_00),
         isIncome: true, usualDay: 28, nextDue: LocalDate(2026, 10, 28), accountID: "enbd"),
    Bill(id: "rent", name: "Rent · Al Habtoor", kind: "Rent", categoryID: "rent", amount: .aed(7_500_00),
         usualDay: 1, nextDue: LocalDate(2026, 11, 1), accountID: "enbd", history: [LocalDate(2026, 10, 1)]),
    Bill(id: "netflix", name: "Netflix", kind: "Streaming", categoryID: "subscriptions", amount: .aed(56_00),
         usualDay: 6, nextDue: LocalDate(2026, 11, 6), accountID: "dib", history: [LocalDate(2026, 10, 6)]),
    Bill(id: "spotify", name: "Spotify", kind: "Music", categoryID: "subscriptions", amount: .aed(21_99),
         usualDay: 8, nextDue: LocalDate(2026, 11, 8), accountID: "dib", history: [LocalDate(2026, 10, 8)]),
    Bill(id: "savings-so", name: "Savings standing order", kind: "Savings", categoryID: "savings",
         amount: .aed(3_000_00), usualDay: 2, nextDue: LocalDate(2026, 11, 2), accountID: "enbd"),
    Bill(id: "sarwa-so", name: "Sarwa", kind: "Investments", categoryID: "investments", amount: .aed(2_000_00),
         usualDay: 2, nextDue: LocalDate(2026, 11, 2), accountID: "enbd"),
  ]

  static let candidates: [BillCandidate] = [
    BillCandidate(id: "apple-bill", name: "Apple.com/bill", categoryID: "subscriptions", amount: .aed(14_99),
                  seenCount: 5, everyDays: 30, last: LocalDate(2026, 10, 8)),
  ]

  static let projects: [Project] = [
    Project(id: "japan", name: "Japan trip", glyph: .travel, budget: .aed(12_000_00),
            starts: LocalDate(2026, 12, 14), ends: LocalDate(2026, 12, 28), startVerb: "flies"),
  ]

  static let goals: [Goal] = [
    Goal(id: "emergency", name: "Emergency fund", glyph: .savingsJar, categoryID: "emergency-fund",
         target: .aed(50_000_00), saved: .aed(38_500_00), by: YearMonth(2027, 1)),
  ]

  static let rules: [Rule] = [
    Rule(id: "r-carrefour", patterns: ["carrefour"], categoryID: "groceries"),
    Rule(id: "r-talabat", patterns: ["talabat"], categoryID: "dining"),
    Rule(id: "r-careem", patterns: ["CAREEM", "UBER"], match: .startsWith, categoryID: "transport"),
    Rule(id: "r-netflix", patterns: ["NETFLIX.COM"], match: .exact, categoryID: "subscriptions"),
    Rule(id: "r-dewa", patterns: ["dewa"], categoryID: "utilities"),
    Rule(id: "r-zuma", patterns: ["zuma"], categoryID: "dining"),
  ]
}
